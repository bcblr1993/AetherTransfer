# WebDAV 开发候选

连接表单提供 WebDAV · HTTPS（默认 443）与 WebDAV · HTTP（默认 80）。填写主机、端口、用户名、密码和起始路径，例如 `/remote.php/dav/files/用户名/`；主机字段不接受整个 URL。HTTPS 始终验证证书链和主机名，不能降级为 HTTP。密码仍由既有 Keychain 流程管理，不写入连接配置。

目录采用 Depth 1 PROPFIND，使用系统 XMLParser 读取 DAV 命名空间内成功的属性。只接受当前目录和直接子项，拒绝跨主机/端口/协议 href、越界或编码分隔符、重复项、缺失根目录、DOCTYPE/ENTITY 和过深 XML；响应上限 32 MiB、目录上限 100,000 项。解析与排序在 worker 上完成。

GET 下载和 PUT 上传保持流式文件 IO、限速、暂停/继续与取消。下载写入本机唯一 `.part` 后提交；上传写入远端唯一 `.part`，再用 MOVE 提交。未明确覆盖时使用 `Overwrite: F`，服务器提交时拒绝已有目标；明确覆盖才使用 `T`。失败或取消尝试清理自身的暂存文件并保留原目标，断网时可能遗留远端 `.part`。若服务器在请求成功后中断连接，最终状态可能不确定，必须刷新目录核对，不能保证服务器端事务回滚。

文件夹使用 MKCOL，重命名使用 MOVE，删除使用 DELETE。普通文件夹删除先检查为空，不自动递归删除；外部客户端在检查后新增子项的竞态仍需处理，当前不能视为原子的“仅删除空目录”。根目录拒绝删除。单向/双向/镜像同步复用既有预览与选择流程，删除仍默认不选中。

仅接受操作对应的 HTTP 成功状态；重定向要求用户填写最终地址，不自动转发凭据或降级。修改请求返回 207 多项错误时不能被报告为成功。认证支持 libcurl 的 Basic 和 Digest；HTTP 仍是明文传输，应优先使用 HTTPS。

隔离验收使用 WsgiDAV 4.3.5 和 Cheroot 11.1.2（MIT，仅测试 venv，不进入应用）。真实服务在 loopback 上运行，文件、证书、SSH 密钥位于 TemporaryDirectory，退出后清理。`./scripts/test_protocols.sh` 覆盖 HTTP/HTTPS 的 1 MiB 中文/空格往返、字节校验、空文件、Basic/Digest、错误密码、证书不可信/名称不符、拒绝明文服务器与重定向、MOVE 不覆盖、非空文件夹保护、取消 PUT 保留原目标、暂停恢复、同步与明确镜像删除。`./scripts/test_core.sh` 覆盖 XML/路径边界。

单个文件支持保留进度和重启恢复。下载要求正确的 Range / Content-Range，并在强 ETag 可用时使用 If-Match；普通 PUT 上传必须明确选择从头上传。内容与版本核对、临时文件清理及限制见 [保留进度与断点续传](resumable-transfers.md)。

尚待完成：真实 Nextcloud/NAS 等服务矩阵、锁定文件编辑、服务器 COPY 的完整界面工作流、目标条件写入与目录任务恢复、外部创建子项的删除竞态、自定义企业 CA 的系统管理流程。当前不接受无用户名匿名服务，也不提供绕过证书验证的开关。

协议依据：[RFC 4918](https://www.rfc-editor.org/rfc/rfc4918.html)、[libcurl HTTPAUTH](https://curl.se/libcurl/c/CURLOPT_HTTPAUTH.html)。
