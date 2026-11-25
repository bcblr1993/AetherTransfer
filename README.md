# AetherTransfer

为 Apple 芯片打造的原生 macOS 文件传输工作台。全面覆盖传统协议与对象存储，在原生 Liquid Glass 界面中提供双栏/分栏浏览、任务调度、目录同步、检查器校验与自动化上传工作流。

**状态：v0.3.0（Transmit 5 深度对齐版）。** [下载](https://github.com/bcblr1993/AetherTransfer/releases/latest) · [官网](https://www.aethernative.com/apps/aethertransfer/) · [对齐矩阵](docs/transmit-parity.md) · [首版范围](docs/first-version.md)

支持 **SFTP、隐式 FTPS、显式 FTPS (`AUTH TLS`)、FTP（Active/Passive 与 ASCII/Binary/Auto）、WebDAV / WebDAV HTTPS、Amazon S3（含服务商预设、`ListBuckets` 与 AWS STS `AssumeRole` + MFA）/ Cloudflare R2 / MinIO、Backblaze B2、Microsoft Azure Blob、OpenStack Swift**。提供 Raw FTP/SFTP 命令控制台、FileZilla / Cyberduck / Transmit / SSH / AWS 书签导入器、防 Zip-Slip 解压、编辑器查找替换与多编码（UTF-8 / UTF-16 / ISO-8859-1 / GB18030）、高级目录同步（时差补偿/最近修改/跟随符号链接/干跑模拟/CSV 导出）、Servers Launchpad（颜色标签、文件夹关联、自定义常用位置）、双栏/本地⇄本地/服务器⇄服务器切换与聚焦模式、列表/级联 Miller 分栏/缩略图网格/画廊预览视图与 View Options（`⌘J`）、三标签文件检查器（文件夹大小、SHA-256/MD5、递归权限、云端元数据与 Presigned URL）、规则过滤引擎与 ASCII 扩展名、脱敏协议日志、Finder Droplets 与 URL Scheme、SSH 密钥管理器与 Known Hosts、按扩展名自定义外部编辑器与保存自动回传、`.aethersync` 零知识加密书签保险箱、菜单栏微件、活跃传输关闭/断连守护与安全应用内更新。需第三方 OAuth 应用凭据的消费级网盘（Box、Dropbox、Google Drive、OneDrive）暂不包含。

## 开发

要求 Apple Silicon、macOS 26+、Xcode 26+ / Swift 6。开发环境使用 Homebrew libcurl（带 SFTP 后端）：

```sh
brew install curl
./scripts/test_core.sh
./scripts/test_protocols.sh
swift run AetherTransfer
```

`scripts/build_app.sh` 生成独立 arm64 `.app`、DMG、ZIP、`SHA256SUMS.txt` 与 `appcast.json`，并嵌入动态依赖、TLS 根证书与第三方许可证；用户安装包不依赖 Homebrew。设置 `NOTARY_PROFILE` 后自动提交 Apple 公证并装订票据，发布流程见 [docs/release.md](docs/release.md)。

## 产品分工

AetherTransfer 专注文件管理与传输；ApexTerm 专注 SSH 终端与运维（支持从当前路径或远程会话联动打开终端）。无追踪、无云端账号要求，凭据保存在系统 Keychain。

## 贡献与安全

见 [贡献规范](CONTRIBUTING.md)、[安全报告](SECURITY.md)、[第三方声明](THIRD_PARTY_NOTICES.md)。请勿在 Issue 中上传密码、私钥、真实服务器配置或未脱敏日志。
