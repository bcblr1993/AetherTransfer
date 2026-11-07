# Transmit 功能对齐矩阵

依据：本机 Transmit 协议菜单与 Panic 官方功能/协议文档（2026-10-07）。目标是等价的文件传输工作流，使用自己的品牌、代码与原生 macOS 26 Liquid Glass 设计。

## 已完成对齐（v0.2.0）

- **协议引擎**：FTP、显式/隐式 FTPS、SFTP（含 `libssh2` 主机密钥 SHA-256 指纹核对）、**WebDAV / WebDAV HTTPS**（RFC 4918 `PROPFIND`/`GET`/`PUT`/`MKCOL`/`MOVE`/`DELETE`）、**Amazon S3 / Cloudflare R2 / MinIO**（原生 `CryptoKit` AWS Signature V4、Virtual-Hosted 与 Path-Style 寻址、`ListObjectsV2`、**S3 Presigned URL 临时签名链接生成**）。
- **浏览器与视图**：本地/远程双栏、多标签会话快照、**列表 / Finder 风格分栏（Miller Columns）/ 网格视图**、排序、搜索、隐藏文件、面包屑路径栏、常用位置、文件信息检查器、Quick Look 预览、同步导航（Sync Browsing）。
- **文件操作**：递归传输、远程移动/重命名、批量重命名、新建/删除、POSIX 权限修改、**跨面板复制粘贴（`⌥⌘C` / `⌥⌘V`）、原地创建副本（Duplicate `⌘D`）、复制路径/URL/S3 签名链接**、Finder 原生双向拖放、ZIP 压缩并上传。
- **传输队列**：活动队列、并发控制（1~10）、暂停/恢复、取消/重试、速度限制（`CURLOPT_MAX_SEND/RECV_SPEED_LARGE`）、断点续传（`.aetherresume`）、**覆盖 / 合并文件夹（Merge）/ 跳过 / 保留两者**、Dock 进度角标。
- **文件夹同步**：本地 ⇄ 远程单向/双向对比预览、逐项勾选排除、**Glob 忽略过滤规则（`.DS_Store, .git, node_modules, *.log`）**、Markdown 同步报告一键导出、默认不删远程文件安全保护。
- **SSH 与连接管理**：收藏/分组、JSON 导入导出、macOS Keychain、**SSH Agent 免密认证（`CURLSSH_AUTH_AGENT`）、`~/.ssh/config` 主机配置自动解析导入、内置 SSH 密钥管理器（`Ed25519` / `RSA-4096` 生成与公钥一键复制）**。
- **编辑与终端联动**：内置单文件文本编辑器、**外部编辑器打开并实时监听保存自动回传（`ExternalEditorManager`）**、**ApexTerm 优先探测联动与 `Terminal.app` 回退**。
- **加密配置同步与菜单栏微件**：**零知识加密书签保险箱（`.aethersync`，`HKDF-SHA256` + `AES-GCM-256`）**、**macOS 菜单栏闪电上传微件（`MenuBarExtra` Droplet）**。
- **应用内更新与本地化**：应用内在线检查更新、流式下载、SHA-256 与 Apple 代码签名双重校验、原子替换立即重启（`AutoUpdater`），以及中英双语实时切换（`L10n`）。

## 后续待办（需第三方 OAuth 应用凭据的专有云盘）

- 第三方专有云存储协议：Backblaze B2 Native API、Box、Dropbox、Google Drive、Microsoft OneDrive / Azure Blob、OpenStack Swift、Rackspace（需独立 OAuth 客户端注册与线上账号验收）。

## 实施顺序

1. 原生工程、GitHub 规范、官网开发中入口、FTP/SFTP 协议与安全基础。
2. 双栏与任务队列、递归/冲突/续传/编辑/文件管理的完整核心工作流。
3. WebDAV、S3/R2 与同步引擎及预览。
4. 剩余云服务、SSH 高级认证、跨 Mac 配置同步与完整回归。
5. 完整目标验收、安装包与官网状态核对。

完整目标不会因阶段一通过而标记完成。各服务需要独立测试账号与 OAuth 应用注册；没有实际凭据时只能验证隔离协议 fixtures，必须记录真实服务验收缺口。

参考：
- https://help.panic.com/transmit/transmit5/features/
- https://help.panic.com/transmit/transmit5/protocols/
- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
