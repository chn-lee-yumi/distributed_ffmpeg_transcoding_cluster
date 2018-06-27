#!/bin/bash

# 分布式FFMPEG转码 v1.2
# 支持任意格式视频转成MP4
# Usage：dffmpeg.sh [input_file] [ffmpeg_output_parameter]
# Usage：dffmpeg.sh test.mp4
# Usage：dffmpeg.sh test.mp4 -c mpeg4
# Usage：dffmpeg.sh test.mp4 -c mpeg4 -b:v 1M
# TODO：?

###配置项
storage_node="hk.gcc.ac.cn"
storage_node_ssh_port=22
compute_node=("us.gcc.ac.cn" "hk.gcc.ac.cn" "cn.gcc.ac.cn") # 计算节点
compute_node_ssh_port=(10022 22 22) # 计算节点的ssh端口
compute_node_weight=(10 50 15) # 计算节点的权重
nfs_path=/srv/distributed_ffmpeg_transcoding_shared_files #共享目录
###配置项结束

upload_path=$nfs_path/upload
tmp_path=$nfs_path/tmp
download_path=$nfs_path/download
input_file=$1
ffmpeg_output_parameter=${@:2}

# display函数，输出彩色
ECHO=`which echo`
display(){
    local type=$1
    local msg=${@:2}
    if [[ $type = "[Info]" ]]; then
        $ECHO -e "\\033[1;36;40m[Info] $msg \\033[0m"
    elif [[ $type = "[Error]" ]]; then
        $ECHO -e "\\033[1;31;40m[Error] $msg \\033[0m"
    elif [[ $type = "[Exec]" ]]; then
        $ECHO -e "\\033[1;33;40m[Exec] $msg \\033[0m"
    elif [[ $type = "[Success]" ]]; then
        $ECHO -e "\\033[1;32;40m[Success] $msg \\033[0m"
    else
        $ECHO -e $@
    fi
}

### 开始函数重载
# 重载cp，记录log
CP=`which cp`
cp(){
    local src=$1
    local dst=$2
    display [Exec] cp ${@:1}
    $CP ${@:1}
}
# 重载rm，记录log
RM=`which rm`
rm(){
    display [Exec] rm ${@:1}
    $RM ${@:1}
}
# 重载ssh，记录log
SSH=`which ssh`
ssh(){
    display [Exec] ssh ${@:1}
    $SSH ${@:1}
}
### 函数重载完毕

# 检查输入文件
if [ -f $input_file ]
then
   display [Info] Input: $input_file
   display [Info] FFmpeg output parameter: $ffmpeg_output_parameter
   filename=$(date +%s) # 用时间戳做文件名
   display [Info] Uploading file, please wait a while. Temporary filename: $filename
   cp $input_file $upload_path/$filename
else
   display [Error] Input error!
   exit
fi

# 计算计算节点总权重
total_weight=0
for i in ${compute_node_weight[*]}
do
    total_weight=$[$total_weight + $i]
done
display [Info] Compute node total weight: $total_weight

# 分发任务
video_length=$(ffprobe -show_format $input_file -loglevel error| grep duration | awk -F = '{printf $2}')
part_start=0
part_end=0
node_number=${#compute_node[*]}
# for i in {0..${#compute_node[*]}} # 不知为啥不能这样写
for ((i=0; i<$node_number; i++))
do
    # echo ${compute_node[$i]},${compute_node_weight[$i]} # 显示计算节点及其权重
    part_end=$(echo "scale=2; $part_start + $video_length * ${compute_node_weight[$i]} / $total_weight" | bc )
    display [Info] Compute node ["${compute_node[$i]}"] : start[$part_start] , end[$part_end]
    # ssh ${compute_node[$i]} -p ${compute_node_ssh_port[$i]} "ffmpeg -ss $part_start -i $upload_path/$filename -to $part_end $ffmpeg_output_parameter $tmp_path/${filename}_$i.mp4 -loglevel error; touch $tmp_path/${filename}_$i.txt" & # -ss在前面，The input will be parsed using keyframes, which is very fast. 但可能会造成视频部分片段重复。
    ssh ${compute_node[$i]} -p ${compute_node_ssh_port[$i]} "ffmpeg -i $upload_path/$filename -ss $part_start -to $part_end $ffmpeg_output_parameter $tmp_path/${filename}_$i.mp4 -loglevel error; touch $tmp_path/${filename}_$i.txt" & # -ss在后面，速度会变慢，但是不会造成视频片段重复
    part_start=$part_end
    echo "file '${filename}_$i.mp4'" >> $tmp_path/${filename}_filelist.txt
done 

# 不断检查任务是否完成
display [Info] Checking if the tasks are completed.
while :
do
    for ((i=0; i<$node_number; i++))
    do
        if [ -f $tmp_path/${filename}_$i.txt ]
        then
            if [ $i==$[$node_number - 1] ] # 如果全部完成了
            then
                break 2
            else
                continue
            fi
        else
            break
        fi
    done
    sleep 1
    display ".\c"
done
display !

# 进行视频拼接
display [Info] Tasks all completed! Start to join them.
ssh $storage_node -p $storage_node_ssh_port "ffmpeg -f concat -i $tmp_path/${filename}_filelist.txt -c copy $download_path/$filename.mp4 -loglevel error"

#清除临时文件和上传的文件
display [Info] Clean temporary files.
rm -r $tmp_path/${filename}*
rm $upload_path/${filename}

display [Success] Mission complete! Output path: [$download_path/$filename.mp4]


# ffmpeg常用命令。参考 https://www.cnblogs.com/frost-yen/p/5848781.html

#ffprobe -v error -count_frames -select_streams v:0  -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 test.mp4 # 计算帧数量，参考 https://stackoverflow.com/questions/2017843/fetch-frame-count-with-ffmpeg

# 截取视频，参考 https://trac.ffmpeg.org/wiki/Seeking
#ffmpeg -ss 00:01:00 -i test.mp4 -to 00:02:00 -c copy cut.mp4
#ffmpeg -ss 1 -i test.mp4 -to 2 -c copy cut.mp4
#ffmpeg -ss 1 -i test.mp4 -t 1 -c copy -copyts cut.mp4
# 获取视频长度
#ffprobe -show_format test_video.mp4 | grep duration | awk -F = '{printf $2}' > /tmp/1.txt

# 合并视频 https://blog.csdn.net/doublefi123/article/details/47276739