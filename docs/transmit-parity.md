# Transmit 功能对齐矩阵

依据：本机 Transmit 协议菜单与 Panic 官方功能/协议文档（2026-10-07）。目标是等价的文件传输工作流，使用自己的品牌、代码与原生 macOS 26 Liquid Glass 设计。

## 已完成对齐（v0.2.0）

- **全协议传输引擎（10 种协议模式 / 8 大协议家族）**：
  - **传统与安全文件协议**：FTP、隐式 FTPS（Implicit TLS，端口 990）、**显式 FTPS（Explicit `AUTH TLS`，端口 21）**、SFTP（基于 `libcurl` + `libssh2`，支持符号链接创建、POSIX 权限修改与 `SHA-256` 主机密钥指纹首次核对及变更拒绝）。
  - **WebDAV 与对象存储**：**WebDAV / WebDAV HTTPS**（RFC 4918 `PROPFIND`、`GET`、`PUT`、`MKCOL`、`MOVE`、`DELETE`、`HEAD`）、**Amazon S3 / Cloudflare R2 / MinIO**（原生 `CryptoKit` AWS Signature V4、Virtual-Hosted 与 Path-Style 寻址、`ListObjectsV2` 分页、分段上传 Multipart Upload、对象元数据编辑与 Presigned URL 临时签名链接）、**Backblaze B2 Native API**（`b2_authorize_account`、分页列表、SHA-1 校验上传、范围下载、复制与临时授权链接）、**Microsoft Azure Blob**（`SharedKey` HMAC 签名、容器列表、BlockBlob 上传、元数据与 SAS 签名链接）、**OpenStack Swift**（v1.0 Auth 令牌、JSON 列表、`X-Copy-From` 复制与临时签名 URL）。
- **多形态浏览器、分栏与双栏来源切换**：
  - 四种文件视图模式：**列表（List，可选权限列）**、**级联分栏（Cascading Miller Columns）**、**缩略图网格（Thumbnail Grid，可调缩放与异步降采样缩略图）**、**画廊预览分栏（Gallery Split）**。
  - **聚焦模式（Focus Mode）**：支持仅左侧、双栏、仅右侧三种布局；**双栏来源切换**支持本地 ⇄ 远程、**本地 ⇄ 本地（Local ⇄ Local）** 与 **远程 ⇄ 远程（Server ⇄ Server）** 跨连接传输。
  - 多标签页工作区与独立会话快照、可交互面包屑路径栏、历史后退/前进、多维排序、实时搜索、隐藏文件开关、Quick Look 预览与 Finder 原生双向拖放。
- **服务器启动台、文件夹关联与常用位置**：
  - **Servers Launchpad**：服务器卡片/列表快速入口、分组与搜索、**颜色标签筛选（ServerColorTag）**、**文件夹关联（Folder Linking：`linkedLocalPath` 连接即自动切换本地目录）**、书签 JSON 导入导出与 macOS Keychain 凭据存储。
  - **常用位置（Custom Places）**：支持系统常用文件夹与用户自定义钉选本地/远程常用路径，并支持向常用位置直接拖放上传或下载。
- **三标签页文件检查器（3-Tab File Inspector `⌘I`）**：
  - **常规（General）**：文件类型、路径、修改时间、本地/远程**文件夹大小汇总计算（Folder Size）**，以及分块流式（64 KiB）**SHA-256 / MD5 校验和**计算。
  - **权限（Permissions）**：交互式 POSIX 权限矩阵、八进制输入与**递归修改权限（Recursive Chmod）**。
  - **云端与链接（Cloud / URLs）**：S3 / R2、Backblaze B2、Azure Blob、OpenStack Swift 对象 `Content-Type` / 自定义元数据读写，以及按有效期生成与一键复制 Presigned / SAS 临时签名链接。
- **文件规则引擎与 ASCII 扩展名**：
  - **Skip Rules 规则引擎（`FileRulesStore`）**：支持按文件名、扩展名、路径、字节大小、修改日期组合谓词规则（全部/任一/均不满足；支持通配符 Glob），作用于文件浏览器、队列传输或目录同步过滤。
  - **ASCII 文本扩展名编辑器（`AsciiFileExtensions`）**：可自定义纯文本/ASCII 识别扩展名并随时恢复默认列表。
- **传输队列与脱敏协议日志抽屉**：
  - 底部双标签抽屉：**传输队列**（状态筛选、置顶 `Move to Top`、一键重试全部失败 `Retry All Failed`、并发 1~10、暂停/恢复、取消、速度限制、实时剩余时间 ETA、上传后自动复制链接、`Merge` 合并文件夹/覆盖/跳过/保留两者冲突策略、`.aetherresume` 断点续传、Dock 角标）与 **协议日志（Transcript）**。
  - **Transcript Logger**：按连接/命令/响应/传输/同步/错误分类记录，内置 `TranscriptRedactor` 严格脱敏密码、口令、Token、签名查询参数、Authorization 头与 URL userinfo，支持搜索、复制与 `NSSavePanel` 脱敏导出。
- **文件夹同步**：
  - 本地 ⇄ 远程单向/双向对比预览，按大小与修改时间比较，集成 `FileRulesStore` 跳过规则与 `.DS_Store` / `.git` / `node_modules` 等 Glob 过滤，支持逐项勾选、Markdown 同步报告导出，以及默认不删除远程多余文件的安全保护。
- **Droplets 闪电上传微应用与 URL Scheme**：
  - **Droplets 导出**：将指定服务器配置与远程目标路径导出为独立 Finder `.app` 上传小工具（`DropletExporter`），拖入文件即自动拉起队列上传。
  - **URL Scheme**：注册 `aethertransfer://`、`sftp://`、`ftp://`、`ftps://`（不含明文持久化凭据），支持外部唤起连接或触发上传。
- **SSH 密钥管理、Known Hosts 与外部编辑联动**：
  - 解析导入 `~/.ssh/config` 主机配置、SSH Agent 免密认证（`CURLSSH_AUTH_AGENT`）、内置 **SSH 密钥管理器（`Ed25519` / `RSA-4096` 生成与公钥复制）** 与 **Known Hosts 管理（`KnownHostsManager`）**。
  - 内置单文件编辑器与 **外部编辑器实时保存自动回传（`ExternalEditorManager`）**，支持 **ApexTerm 优先与 `Terminal.app` 回退** 在当前路径或远程会话打开终端。
- **加密配置同步、菜单栏微件与安全更新**：
  - **零知识加密书签保险箱（`.aethersync`）**：使用 `HKDF-SHA256` + `AES-GCM-256` 导出与导入加密书签配置。
  - **菜单栏微件（`MenuBarExtra` Droplet）**：实时展示活跃任务与 ETA、快捷复制上次上传链接、拖拽触发上传与快速导出 Droplet。
  - **应用内更新（`AutoUpdater`）**：检查 `appcast.json`、流式下载并核对 SHA-256 与 Apple 代码签名后原子替换重启，支持中英双语实时切换。

## 后续待办（需第三方 OAuth 应用凭据的消费级云盘）

- 消费级 OAuth 专有云盘协议：**Box、Dropbox、Google Drive、Microsoft OneDrive**（需向各平台注册独立第三方 OAuth 客户端凭据并通过线上账号授权流程验收，当前版本未包含）。

## 实施顺序

1. 原生工程、GitHub 规范、官网开发中入口、FTP/SFTP 协议与安全基础。（已完成）
2. 双栏与任务队列、递归/冲突/续传/编辑/文件管理的完整核心工作流。（已完成）
3. 全协议引擎（WebDAV/S3/R2/B2/Azure/Swift/Explicit FTPS）、Miller 分栏/画廊/聚焦模式、Servers Launchpad、三标签检查器、规则引擎、脱敏日志、Droplets 与 `.aethersync`。（已完成 `v0.2.0`）
4. 消费级 OAuth 云盘集成与真机账号长稳验收。（后续版本）

参考：
- https://help.panic.com/transmit/transmit5/features/
- https://help.panic.com/transmit/transmit5/protocols/
- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
