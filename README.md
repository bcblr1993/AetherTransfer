# AetherTransfer

为 Apple 芯片打造的原生 macOS 文件传输工作台。双栏浏览本地与远程文件，连接 FTP / FTPS / SFTP 服务器，管理传输任务。

**状态：v0.1.0 开发中，尚未发布。** [官网](https://www.aethernative.com/apps/aethertransfer/) · [首版范围](docs/first-version.md)

## 开发

要求 Apple Silicon、macOS 26+、Xcode 26+ / Swift 6。开发环境使用 Homebrew libcurl（带 SFTP 后端）：

```sh
brew install curl
swift test
swift run AetherTransfer
```

`scripts/build_app.sh` 生成可运行的开发 `.app` 并嵌入动态依赖。用户安装包不能依赖 Homebrew。

## 产品分工

AetherTransfer 专注文件管理与传输；ApexTerm 专注 SSH 终端与运维。无追踪、无云端账号要求，凭据保存在系统 Keychain。

## 贡献与安全

见 [贡献规范](CONTRIBUTING.md)、[安全报告](SECURITY.md)、[第三方声明](THIRD_PARTY_NOTICES.md)。请勿在 Issue 中上传密码、私钥、真实服务器配置或未脱敏日志。
