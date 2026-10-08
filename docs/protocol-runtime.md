# 可复现的协议库

本机与 CI 均使用项目内构建的 curl 8.22.0 + SSH 私钥口令修复，不依赖本机已安装 curl 的版本。`scripts/build_protocol_runtime.sh` 下载官方发布源码，核对 SHA-256，应用仓库内可审查补丁，输出到 `.build/protocol-runtime`；不会替换 Homebrew 安装。OpenSSL 和 libssh2 仍取 Homebrew，实际动态库随开发 app 嵌入。

curl 8.22.0 的加密 SSH 私钥认证存在上游回归：连接初始化从尚未填充的 TLS 配置读取口令。补丁只回移上游提交中 libssh2 相关的口令读取、复制和释放，不降低认证或证书验证。正确口令认证、错误口令拒绝仍在真实 SFTP 门禁中验证。

同一补丁另修正 SFTP stat 将明确的零字节大小当作未知大小的判断；保留服务器返回的 SIZE 属性，只有 stat 失败或缺少 SIZE 时才使用未知大小。该部分是本项目补丁，并非上游回移。空文件依旧核对大小和修改时间，不能通过放宽安全版本检查解决。真实 SFTP 空文件版本回归与六种协议的目录往返覆盖此路径。[对应 curl 源码](https://github.com/curl/curl/blob/curl-8_22_0/lib/vssh/libssh2.c)

依赖构建前删除上一次源码工作目录，完成后再次清理；仅保留一份校验过的源码压缩包、运行库和当前构建日志。Swift 测试/打包入口在每轮启动前删除旧产物，测试 pip 使用 `--no-cache-dir`；不产生按时间累积的构建目录。大体积动画 trace 和官网生成缓存使用受限的 `clean_generated.py all` 清理。当前本机 Homebrew OpenSSL 依赖的最低系统为 27，macOS 26 正式候选必须由 26 环境构建并验收完整依赖闭包；本机开发 app 不能当作 26 安装证明。

- [上游问题 #22994](https://github.com/curl/curl/issues/22994)
- [上游修复提交 a7b42cc](https://github.com/curl/curl/commit/a7b42cc90cbcb09f4813253ac97ea96c10fd9e94)
- [源码校验值来源 Homebrew 配方](https://github.com/Homebrew/homebrew-core/blob/master/Formula/c/curl.rb)

未来升级到包含该修复的正式发布版本时，应移除回移补丁并重跑全部协议、打包与真实界面门禁。正式发行仍需固定 OpenSSL/libssh2 的版本与许可证，并核查安全更新；当前仅是开发候选。
