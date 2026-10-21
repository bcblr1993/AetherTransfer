# AetherTransfer

为 Apple 芯片打造的原生 macOS 文件传输工作台。双栏浏览本地与远程文件，连接 FTP / FTPS / SFTP 服务器，管理传输任务。

**状态：v0.1.0 首个正式版。** [下载](https://github.com/bcblr1993/AetherTransfer/releases/latest) · [官网](https://www.aethernative.com/apps/aethertransfer/) · [首版范围](docs/first-version.md)

支持 SFTP / FTPS / FTP、双栏多标签浏览、有界传输队列与断点续传、目录差异同步、快速查看、内置文本编辑、批量重命名、权限编辑、中英文界面和应用内更新。WebDAV、S3 / R2 等云存储尚未包含在本版本中。

## 开发

要求 Apple Silicon、macOS 26+、Xcode 26+ / Swift 6。开发环境使用 Homebrew libcurl（带 SFTP 后端）：

```sh
brew install curl
swift test
swift run AetherTransfer
```

`scripts/build_app.sh` 生成独立 arm64 `.app`、DMG、ZIP、`SHA256SUMS.txt` 与 `appcast.json`，并嵌入动态依赖；用户安装包不依赖 Homebrew。设置 `NOTARY_PROFILE` 后自动提交 Apple 公证并装订票据，发布流程见 [docs/release.md](docs/release.md)。

## 产品分工

AetherTransfer 专注文件管理与传输；ApexTerm 专注 SSH 终端与运维。无追踪、无云端账号要求，凭据保存在系统 Keychain。

## 贡献与安全

见 [贡献规范](CONTRIBUTING.md)、[安全报告](SECURITY.md)、[第三方声明](THIRD_PARTY_NOTICES.md)。请勿在 Issue 中上传密码、私钥、真实服务器配置或未脱敏日志。
