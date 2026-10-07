# Transmit 功能对齐矩阵

依据：本机 Transmit 协议菜单与 Panic 官方功能/协议文档（2026-10-07）。目标是等价的文件传输工作流，使用自己的品牌、代码与原生 macOS 26 Liquid Glass 设计。

## 完整目标（未实现的项继续保持待办）

- 协议：FTP、显式/隐式 FTPS、SFTP、WebDAV/HTTPS、S3/IAM Role、B2、Box、DreamObjects、Dropbox、Google Drive、Azure、OneDrive/Business、OpenStack Swift、Rackspace。
- 浏览器：本地/远程、远程/远程、多标签、列表/图标/列视图、排序、搜索、隐藏文件、路径栏、常用位置、文件信息、预览。
- 文件操作：递归传输、远程复制/移动、批量重命名、创建/删除、权限/时间戳、复制粘贴、Finder 拖放、压缩上传。
- 传输：活动队列、并发、暂停/恢复、取消/重试、速度限制、断点续传、覆盖/跳过/保留两份、目录合并、Dock 进度。
- 同步：本地/远程、本地/本地、远程/远程，单向/双向/镜像，差异预览、逐项排除、规则过滤、日志。
- 连接：收藏/分组/历史、导入导出、Keychain、SSH config/agent/ProxyCommand、密钥管理、2FA/OTP、主机密钥核对。
- 编辑：内置文本编辑器、外部编辑器保存回传、在终端打开。
- 配置同步：加密跨 Mac 同步、明确冲突和密钥边界。
- 系统体验：中英文、状态恢复、无障碍、快捷键、浅深色、减少透明度、系统原生工具栏与侧栏。

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
