# 开发记录

2026-10-07：项目从空目录创建。当前是基础实现，完整 Transmit 对齐目标尚未完成。

已验证：Swift 6 编译；路径/配置/目录解析 4 个单元测试；真实隔离 FTP 和 SFTP 1 MiB 中文/空格文件上传下载字节一致、目录创建、重命名、删除、冲突拒绝、主机密钥首次及变更拒绝、失败保留本地原文件；arm64 开发 `.app` 独立依赖嵌入和 ad-hoc 签名；实际启动窗口与连接表单。

发现并修复：SFTP day-month 日期解析；嵌套 @rpath 动态库缺失导致的启动失败。开发应用已恢复运行。

官网：双语开发中产品介绍及隐私政策，未发布安装包，无虚构下载和性能指标。官网完整构建通过 165 测试及链接校验；推送和线上验证记录另补充。

2026-10-16：按照严格 TDD 模式完成 Transmit 对齐核心能力与 macOS 26/27 Liquid Glass 设计重构：
- TDD 核心引擎开发：
  - 目录差异同步与同步计划引擎（`SyncEngine`、`SyncPlan`、`SyncItem`，支持本地到远程、远程到本地、双向同步最新优先，支持大小与修改时间或仅大小比对；严格遵守安全规范，默认不删除远程多余孤儿文件，生成交互式计划预览）。
  - 有界并发传输队列管理引擎（`TransferQueueManager`，默认最大 3 并发，FIFO 调度，支持带宽限速调节 `speedLimitBytesPerSec`，取消、失败重试、清除已完成、实时速度统计与格式化）。
  - 递归目录传输（`LocalFiles.walk` 遍历本地树、`RemoteClient.listRecursive` 与 `mkdirRecursive` 递归创建与上传下载）。
  - 历史回退/前进导航机制（`NavigationHistory`、`RemotePath.breadcrumbs` 面包屑分段）。
  - 冲突处理与自动重名规则（`ConflictResolution`、`RemotePath.uniqueName`）。
  - 文件多维排序与类型解析（按名称、大小、修改日期、种类排序与中英文种类描述）。
  - 服务器收藏分组管理与常用位置（`ServerProfile.grouped`、`PlaceItem`）及书签 JSON 导入导出（`ServerProfile.exportJSON` / `importJSON`）。
  - Transmit 同步浏览导航（`SyncNavigationManager`，支持在本地与远程窗格保持镜像层级联动）。
  - 压缩并上传引擎（`ArchiveHelper`，一键将本地单项或多项文件压缩为 zip 并安全上传至远程服务器）。
  - 有界并发传输队列管理引擎（`TransferQueueManager`，默认最大 3 并发，FIFO 调度，支持暂停/恢复 `pause/resume`、带宽限速调节 `speedLimitBytesPerSec`，取消、失败重试、清除已完成、实时速度统计与格式化，联动 macOS Dock 实时角标显示）。
  - Transmit 多标签页工作区模型（`TabSessionManager`，支持 ⌘T 新建、⌘W 关闭与独立导航上下文）。
  - POSIX 权限解析与交互式修改器（`POSIXPermissions`、`PermissionTriad`，支持八进制 0755/0644 与远程/本地 chmod）。
  - 批量重命名引擎（`BatchRenamer`，支持文本替换、前缀/后缀、序列编号与冲突规避）。
  - 内置文本/代码编辑器（`TextFileHelper`、`QuickEditorSheet`，支持双击编辑与 ⌘S 安全回传）。
  - 终端联动（支持在当前本地路径或远程 SSH 会话打开终端）。
- macOS 26/27 Liquid Glass UI 对齐：
  - 采用原生 `.ultraThinMaterial`、`.glassProminent` 与毛玻璃分割布局。
  - 同步浏览切换开关（Toolbar 按钮，动态指示联动状态）。
  - 目录同步交互面板（`SyncSheet`），支持方向选择、比较规则切换、安全性防误删保护复选、差异状态胶囊统计与逐项复选开关。
  - Quick Look 快速查看集成（支持空格键、工具栏 👁️ 与右键菜单唤起；本地直接预览，远程文件流式下载至临时缓存无感预览）。
  - 访达与双窗格拖拽支持（支持从访达拖拽文件直接上传至远程或本地目录）。
  - 顶部流体毛玻璃多标签页栏（TabBarView）。
  - 可交互式面包屑路径栏（支持分段点击跳转与手动路径编辑切换）。
  - 双模式视图切换（列表 Table 与图标网格 Grid 模式）。
  - Transmit 风格文件详细检查器面板（⌘I，快捷查看种类、详细字节、权限矩阵与完整路径）。
  - 批量重命名交互面板与实时计划预览（BatchRenameSheet）。
  - 内置极简代码编辑器面板（QuickEditorSheet）。
  - 底部可折叠传输队列抽屉（实时网速 ⚡️、队列暂停/恢复、带宽限速下拉调节、总体进度、任务取消/重试控制）。
  - 侧边栏常用位置（个人文件夹、桌面、文稿、下载）、服务器分组管理与书签导入/导出工具。
  - 断点续传与弹性恢复引擎（`ResumableTransfer`、`ResumeTransferStore`、`LocalFileCommit`，基于 Darwin `renamex_np` 原子提交，支持 SHA-256 指纹核验、本地与远端篡改拦截保护，结合 CTransfer 底层 `at_transfer_window` 与 `CURLOPT_RESUME_FROM_LARGE` 实现真实 FTP/SFTP 上传下载续传）。
- 全量门禁验证通过：
  - 53 个单元测试全部通过（`swift test`）。
  - 7 个隔离 FTP / SFTP 真实集成测试通过（含递归目录传输校验与断点续传/篡改防护校验，`scripts/test_protocols.sh`）。
  - Release 构建通过（`swift build -c release` 与 `scripts/build_app.sh`），成功生成独立 arm64 `.app` 包，闭包依赖嵌入与 Developer ID Application 签名校验通过，实际启动运行正常。

2026-10-21：完成 v0.1.0 正式版发布闭环与内置在线更新系统：
- 原生应用内在线更新引擎（`AutoUpdater`、`SoftwareUpdateSheet`、`SemanticVersion`、`UpdateManifest`）：支持自动/手动检查更新、流式下载进度展示、SHA-256 摘要校验、`codesign --verify --deep --strict` 代码签名校验、原子替换 `.app` 包并立即重启应用。
- 底层限速与交互闭环：`CTransfer` 新增 `at_set_speed_limit` 打通 `CURLOPT_MAX_SEND_SPEED_LARGE` / `CURLOPT_MAX_RECV_SPEED_LARGE`；双栏表格排序菜单与双向拖拽（`.draggable` + `.dropDestination`）落地；支持已保存书签编辑与 Keychain 凭据回填；`openTerminal` 增加 `ShellEscape` 单引号与 AppleScript 转义加固；递归目录传输统一接入 `ResumableTransfer`。
- 中英文双语国际化（`L10n`、`AppLanguage`）：支持跟随系统语言及菜单栏实时切换中英文，补充无障碍标签。
- 发行打包升级：`scripts/build_app.sh` 自动生成 `AppIcon.icns`，执行 Developer ID Application (Hardened Runtime) 签名，产出 `AetherTransfer-0.1.0-arm64.dmg`、`AetherTransfer-0.1.0-arm64.zip`、`SHA256SUMS.txt` 与 `appcast.json`。

仍需：WebDAV / S3 / R2 等云协议扩展。公共发行签名、公证与下载发布门禁尚未完成。
