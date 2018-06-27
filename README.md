# 分布式FFMPEG转码集群

## 代码思路

- 分布式转码集群
- 暂时的目标: FFMPEG实现任意格式转MP4。
- 存储暂时采用单节点的共享存储(NFS)，可尝试分布式存储。
- 所有节点对CPU架构无要求，可使用x86+ARM。
- 控制节点和计算节点通信暂时使用SSH。
- 思路: 控制节点收到请求，将文件传到共享存储，计算视频总帧数，然后发送命令给计算节点，不同节点按照各自权重(手动设置，可加性能测试功能)处理一定的连续帧，输出到共享存储，全部节点转码完毕后交由存储节点进行合并，并清理共享临时文件，最后控制节点返回转码后的视频链接。

## 已知问题（待解决）

- **ffmpeg还在运行但已经执行了后面的touch语句**，导致控制代码认为节点已经转码完成。这个我还没想明白为什么。代码如下：
```shell
# ssh ${compute_node[$i]} -p ${compute_node_ssh_port[$i]} "ffmpeg -i $upload_path/$filename -ss $part_start -to $part_end $ffmpeg_output_parameter $tmp_path/${filename}_$i.mp4 -loglevel error; touch $tmp_path/${filename}_$i.txt"
ssh 10.1.1.172 -p 22 ffmpeg -i /srv/distributed_ffmpeg_transcoding_shared_files/upload/1530104749 -ss 0 -to 8.76 -c:v mpeg4 -b:v 1M /srv/distributed_ffmpeg_transcoding_shared_files/tmp/1530104749_0.mp4 -loglevel error && touch /srv/distributed_ffmpeg_transcoding_shared_files/tmp/1530104749_0.txt
```

## 安装与配置

- 测试组网：三台公网VPS cn.gcc.ac.cn, hk.gcc.ac.cn, us.gcc.ac.cn
- 存储节点：hk.gcc.ac.cn
- 控制节点：cn.gcc.ac.cn
- 计算节点：cn.gcc.ac.cn,hk.gcc.ac.cn,us.gcc.ac.cn

### 存储节点

- 存储节点系统是Debian

```shell
# 安装NFS
apt-get install nfs-kernel-server
# 新建共享文件夹，用于放渲染前上传的文件、渲染后的分片文件、渲染后的完整文件。
mkdir -p /srv/distributed_ffmpeg_transcoding_shared_files
mkdir /srv/distributed_ffmpeg_transcoding_shared_files/upload
mkdir /srv/distributed_ffmpeg_transcoding_shared_files/tmp
mkdir /srv/distributed_ffmpeg_transcoding_shared_files/download
chmod -R 777 /srv/distributed_ffmpeg_transcoding_shared_files
```

- 修改文件`/etc/exports`，将目录共享出去
- upload目录，控制节点有读写权限，计算节点有只读权限
- tmp，计算节点有读写权限
- download目录，存储计算节点有读写权限（由于这里只有单节点存储，就不需要共享了）

```shell
# /etc/exports: the access control list for filesystems which may be exported
#               to NFS clients.  See exports(5).
#
# Example for NFSv2 and NFSv3:
# /srv/homes       hostname1(rw,sync,no_subtree_check) hostname2(ro,sync,no_subtree_check)
#
# Example for NFSv4:
# /srv/nfs4        gss/krb5i(rw,sync,fsid=0,crossmnt,no_subtree_check)
# /srv/nfs4/homes  gss/krb5i(rw,sync,no_subtree_check)
#
/srv/distributed_ffmpeg_transcoding_shared_files/upload cn.gcc.ac.cn(ro,insecure) us.gcc.ac.cn(ro,insecure)
/srv/distributed_ffmpeg_transcoding_shared_files/tmp cn.gcc.ac.cn(rw,insecure) us.gcc.ac.cn(rw,insecure)
```

- **注：特别注意要用insecure，否则会挂载不上，显示access denied。这个坑了我好久。**
- 修改完后用`exportfs -arv`生效。可以使用`showmount -e`查看。

### 计算节点

```shell
# 新建目录
mkdir -p /srv/distributed_ffmpeg_transcoding_shared_files/upload
mkdir -p /srv/distributed_ffmpeg_transcoding_shared_files/tmp
# 挂载NFS，这里只是临时挂载，可以修改fstab或开机启动脚本进行自动挂载
mount hk.gcc.ac.cn:/srv/distributed_ffmpeg_transcoding_shared_files/upload /srv/distributed_ffmpeg_transcoding_shared_files/upload
mount hk.gcc.ac.cn:/srv/distributed_ffmpeg_transcoding_shared_files/tmp /srv/distributed_ffmpeg_transcoding_shared_files/tmp
# 安装ffmpeg
apt-get install ffmpeg
```
- 注：现在jessie要在`source.list`添加`deb http://ftp.debian.org/debian jessie-backports main`才能找到这个包。

### 控制节点

```shell
# 生成ssh公钥并拷贝到计算节点
ssh-keygen -t rsa
ssh-copy-id -i ~/.ssh/id_rsa.pub hk.gcc.ac.cn # 拷贝公钥到计算节点
ssh-copy-id -i ~/.ssh/id_rsa.pub us.gcc.ac.cn -p 10022 # 拷贝公钥到计算节点，这个节点的ssh端口是10022
# 创建并挂载upload目录
mkdir -p /srv/distributed_ffmpeg_transcoding_shared_files/upload
mount hk.gcc.ac.cn:/srv/distributed_ffmpeg_transcoding_shared_files/upload /srv/distributed_ffmpeg_transcoding_shared_files/upload
```

下载`dffmpeg.sh`并加执行权限。脚本使用方法如下：

```
Usage：dffmpeg.sh [input_file] [ffmpeg_output_parameter]
Usage：dffmpeg.sh test.mp4
Usage：dffmpeg.sh test.mp4 -c:v mpeg4
Usage：dffmpeg.sh test.mp4 -c:v mpeg4 -b:v 1M
```

## 测试

- 在控制节点运行：`dffmpeg.sh test_video.mp4 -c:v mpeg4 -b:v 1M`
- 其中test_video.mp4为需要转码的文件，mpeg4是编码格式，1M是视频码率。
- 最后会输出一个mp4文件在download目录。
- 由于我的三个服务器分布在公网不同地域，瓶颈在NFS的读写速度，所以最终转码速度会比较慢。如果服务器先缓存了要转码的文件，那么最终转码速度是比一台服务器转码快的。
- 代码运行效果如下图
![代码运行效果图](https://img-blog.csdn.net/2018062412264794?watermark/2/text/aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L2ltZHlm/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70)
- 转码后的视频可以看dffmpeg_result.mp4。（这个是我用树莓派集群转的）

## 结束语

- 觉得这个好玩，所以我就写了。本来是打算用几个树莓派做测试的，不过树莓派现在只有一个，先用VPS测试一下。
- 脚本中有一段注释了的代码`for i in {0..${#compute_node[*]}}`，这是我一开始的写法，但是发现不能用。我不知道为什么不能那样写，所以写成`for ((i=0; i<$node_number; i++))`。如果知道答案的还请指点一下。
- 我觉得`不断检查任务是否完成`那部分的判断代码不大好看，不知道有没有更简洁的方法。

## 更新日志

 - v1.1：修复问题：最后的视频长度会比原来长。原因在于`-ss`参数的位置，详见代码注释。
 - v1.2：新增内容：支持FFmpeg输出参数。输出彩色详细信息。

## 我的博客相关文章

 - [分布式FFMPEG转码集群](https://blog.csdn.net/imdyf/article/details/80621009)
 - [树莓派集群（分布式FFMPEG转码）](https://blog.csdn.net/imdyf/article/details/80828218)
