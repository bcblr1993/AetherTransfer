# AetherTransfer

为 Apple 芯片打造的原生 macOS 文件传输工作台。双栏浏览本地与远程文件，连接 FTP / FTPS / SFTP / WebDAV（HTTP、HTTPS）服务器与 S3 存储桶，管理传输任务。

**状态：v0.1.0 开发中，尚未发布。** [官网](https://www.aethernative.com/apps/aethertransfer/) · [首版范围](docs/first-version.md)

开发候选已包含单向/双向目录差异预览、逐项方向选择和明确的镜像删除确认，支持本地与已连接远程目录的组合。使用方法和当前限制见 [目录同步](docs/synchronization.md)。文件查看入口与缓存边界见 [快速查看与文件信息](docs/file-preview.md)。

本地与远程窗格可独立选择原生列表或图标视图；切换保留文件选择，支持排序、键盘多选、快速查看和共享右键操作。两种视图共用原生文件 URL 拖入入口，上传前固定目标连接和路径；最终候选与 Finder 拖放仍待验收，见 [文件浏览](docs/file-browser.md)。

本地与远程 UTF-8 文本可在原生窗口编辑，或选择本机编辑器后保存自动回传；内容冲突会保留草稿。编码、大小与并发写入限制见 [文本编辑](docs/editing.md)。

单个文件可保留进度并在重启后恢复；恢复前核对源、已传内容和目标。WebDAV 上传需明确选择从头上传。支持范围与空间清理见 [续传](docs/resumable-transfers.md)。

S3 开发候选已接入原生连接表单、前缀浏览、文件与递归目录队列传输、冲突策略及分片清理记录。S3 同步/编辑/预览/重启恢复和 AWS/R2 真实账户仍待验收。范围、目录映射与分片清理边界见 [S3 连接与传输](docs/s3.md)。

## 开发

要求 Apple Silicon、macOS 26+、Xcode 26+ / Swift 6。协议库在项目自己的 `.build` 中构建，不修改本机 Homebrew curl：

```sh
brew install openssl@3 libssh2
./scripts/build_protocol_runtime.sh
./scripts/test_core.sh
python3 scripts/clean_generated.py swift
swift run AetherTransfer
```

`scripts/build_app.sh` 生成可运行的开发 `.app` 并嵌入动态依赖。用户安装包不能依赖 Homebrew。

测试和打包脚本会先清理上一轮 Swift 构建产物；打包只保留一个开发 app。依赖源码编译完成即清理，仅缓存一份协议 runtime、源码压缩包和测试 venv。官网构建前后用 `python3 scripts/clean_generated.py website` 清理 node_modules、dist、Astro 和 npm 缓存。手动清理本项目生成的性能追踪与所有构建缓存：`python3 scripts/clean_generated.py all`；该命令保留源码、Git 与官网 checkout，不删除用户的待续传数据。

测试和构建串行执行，结束后再清理 `swift`、`runtime`、`website` 三个范围，保留一个当前开发 app 和少量验收证据；不保留多轮编译目录或大型性能追踪。预览缓存独立于构建清理：关闭或正常退出清理自己的副本，启动时回收已确认归属且无人使用的遗留副本，未知数据保留。

`scripts/test_s3.sh` 会先清理 Swift 产物，编译独立 MinIO 测试服务（需要 Go 1.24+），随即移除 Go 模块/编译缓存，测试退出时删除服务程序与自建数据。它不会增加 app 的生产依赖或将 MinIO 打包进应用。

## 产品分工

AetherTransfer 专注文件管理与传输；ApexTerm 专注 SSH 终端与运维。无追踪、无云端账号要求，凭据保存在系统 Keychain。

## 贡献与安全

见 [贡献规范](CONTRIBUTING.md)、[安全报告](SECURITY.md)、[第三方声明](THIRD_PARTY_NOTICES.md)。请勿在 Issue 中上传密码、私钥、真实服务器配置或未脱敏日志。
