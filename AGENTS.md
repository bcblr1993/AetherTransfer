# AetherTransfer 开发规范

原生 Apple Silicon macOS 文件传输客户端，Swift 6 + SwiftUI / AppKit。

- 先读现有实现，保持修改范围明确。不得提交服务器凭据、主机地址、私钥或测试生成文件。
- 首版 v0.1.0 范围以 `docs/first-version.md` 为准；不以空界面或 mock 传输代替真实协议验收。
- 网络与文件 IO 离开主线程；有界缓冲；任务必须可取消。取消或失败不得把部分文件报告为成功。
- SFTP 必须验证主机密钥，首次连接让用户核对指纹；密钥变化拒绝连接。TLS 必须验证证书。
- 密码和密钥口令存入 Keychain；连接资料只保存非秘密字段。日志不得包含凭据或 URL userinfo。
- 删除与覆盖必须由用户具体操作触发；同步先预览，不默认删除远程文件。
- 唯一当前生产依赖为 libcurl（其 SFTP 后端 libssh2）；添加依赖前说明用途、许可证和打包方式。
- 提交采用 Conventional Commits；PR 说明行为、验证和剩余限制。新功能在 `feat/*` 分支。
- 每次测试/构建前清理上一次生成产物，使用 `scripts/test_core.sh`、`scripts/test_protocols.sh`、`scripts/build_app.sh` 与 `scripts/benchmark.sh`。手动 Swift 命令前先运行 `python3 scripts/clean_generated.py swift`。不要累积旧 app、依赖源码编译目录、性能追踪或官网 node_modules/dist；提取结论后清理大型追踪，只保留少量当前证据。源码、Git、用户文件不得作为清理对象。
- 门禁：单元测试、release 构建、真实 FTP/SFTP/FTPS 集成测试、运行界面检查。
- 官网产品内容在 `website_content/apps/aethertransfer/`，同步只改对应目录。未发布时标记 dev，无虚构下载或性能指标。
- Release 另需 arm64 独立打包、依赖嵌入、Developer ID 签名、公证、校验和、公开下载验证。
