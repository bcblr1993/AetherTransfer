# SFTP 认证

开发候选在共用连接表单中提供“密码 / 私钥文件 / SSH agent”。选择一种方式后，只显示需要的字段；切换方式清空密码、口令与保存选择。服务器地址、用户名、路径和私钥文件草稿保留。原生窗口、中英文浅深色、输入法和键盘操作仍待当前候选实机验收。

密码方式只发送密码。私钥文件方式只使用所选文件和口令，支持原有加密 RSA 路径。SSH agent 使用应用进程环境中的 `SSH_AUTH_SOCK` 连接已运行的系统 agent，由 agent 使用已加载的密钥签名；应用不保存 agent 的私钥或口令。失败不会改用另两种方式。缺失环境时显示可处理的错误；过期 socket 或无可用密钥时连接失败。软件不创建或管理用户 agent。

旧收藏缺少新认证字段时保持既有行为：有私钥路径使用该私钥，否则使用密码。显式认证选择写入非秘密连接资料。导入收藏重置主机信任、私钥路径及 agent 选择，需要用户重新选择本机认证方式；导入标识不能读取已有 Keychain 凭据。

## 凭据与主机信任

`Credentials.forProfile` 在进入客户端、工作区和 Keychain 保存入口时，仅保留选定方式需要的秘密。agent 读取收藏不查询 Keychain；密码模式只读密码，私钥文件模式只读口令。更换收藏时，现有独立凭据绑定和退役记录负责清理旧凭据。认证或私钥路径变化使进行中的凭据读取失效，避免把旧端点／旧密钥口令填回表单。

认证选择与主机连接标识分开：切换认证方式不主动取消同一端点已核对的主机密钥。所有方式继续执行原有 SFTP 主机密钥回调，首次连接需要核对指纹，主机密钥变化拒绝连接。TLS 和其他协议的认证流程沿用原有实现。

## 验证

四个核心用例覆盖旧 JSON、显式方式往返与未知值拒绝、凭据隔离与 agent 的 Keychain 读取旁路、导入不授权本机认证，以及凭据／主机标识与私钥路径校验。

六个真实 SFTP 用例验证：agent 中文／空格文件往返、摘要与源保留，创建／重命名／删除；各方式失败后不使用另一种有效凭据；agent 仍要求主机信任；服务器已观察到 agent 认证后取消，不发布列表且有界返回；agent 已停止时拒绝认证。测试脚本使用自己的 `/tmp` 私有目录、agent 进程和密钥，只向子测试进程设置 socket，不向用户 agent 添加密钥。停止后清理 socket／临时密钥，再从 Swift 清理入口重编译并执行失效 agent 用例。完整 FTP／两种 FTPS／WebDAV 与 S3 门禁仍须核对最终同一提交。

## 本机 SSH 配置

连接表单可明确启用“读取本机 SSH 配置”，默认关闭，旧收藏保持手动连接行为。读取 `~/.ssh/config`，再读取 `/etc/ssh/ssh_config`；标量采用先取得的值，IdentityFile 累积。支持 Host 的通配／排除、HostName、User、Port、引号／注释／等号及有界 Include。用户输入的用户名优先；留空时用配置或本机短用户名。端口单独选择跟随配置（无配置时 22）或手动指定。

私钥方式可以留空文件路径，使用配置中第一个存在的普通私钥文件；手动选择的文件优先且不可用时不改选配置密钥。支持 `~/`、`${变量}` 和 `%% / %h / %n / %r / %u / %d / %p` 路径展开；HostName 仅接受 `%% / %h`。未实现多密钥认证重试及默认密钥搜索。配置不会改变显式认证方式；PasswordAuthentication、PubkeyAuthentication、PreferredAuthentications 的禁止项生效。IdentityAgent none 禁用 agent；IdentitiesOnly yes 的 agent 筛选尚不支持，选择 agent 时拒绝继续。

配置解析在可取消 worker 内执行，每次连接冻结实际主机、端口、用户和选定私钥。表单先解析，再保存／关闭，错误保留草稿。收藏保留原别名与非秘密字段，Keychain 绑定不变。指纹弹窗显示实际端点；已核对指纹与实际端点绑定，别名改指另一端点时重新核对，同一端点主机密钥变化仍拒绝。核对／保存后不会重读配置来改变用户刚批准的目标。续传使用实际端点标识；导入重置配置读取、端口选项、主机信任和端点绑定。

读取限制为每文件 256 KiB、总量 1 MiB、最多 32 文件、8 层、32 密钥路径、每行 8 KiB。Include 只在最后一段文件名支持 glob，按字节词序处理，父目录枚举最多 4096 项；相对路径使用用户／系统 SSH 根目录，包含文件的条件不会影响父文件。拒绝循环、非普通文件、非用户／root 所有或组／其他可写的配置文件，不执行 shell 或 `ssh -G`。Match、ProxyCommand／ProxyJump、自定义 agent socket、证书／硬件密钥、算法策略及其他未实现的活动指令明确报错；不默默直连。SendEnv、SetEnv、RequestTTY、ForwardX11、ForwardX11Trusted、ForwardAgent、LogLevel、VisualHostKey 属会话／显示配置，在文件请求中忽略。这是支持明确子集的读取入口，并非完整 OpenSSH 配置兼容。

14 项新增核心用例验证优先级、条件／词序 Include、路径展开、显式覆盖、认证策略、端点信任与冻结、凭据重绑定、导入、取消、文件权限／FIFO／容量／循环边界。3 项新增真实 SFTP 用例验证配置别名首次信任、冻结目标的中文／空格文件往返、加密配置私钥及失败不回退、实际端点密钥变化拒绝。原生窗口及完整双语四组合仍待当前候选实机检查。

## 完整对齐待办

此阶段提供显式认证方式和上述 SSH 配置子集。Transmit 的自动认证顺序、完整 SSH config、多密钥与默认密钥搜索、ProxyCommand／跳板机、OTP／键盘交互、PKCS#11／硬件密钥、密钥生成与管理仍属完整目标。系统 agent 的其他密钥格式、锁定／交互提示以及真实服务器与当前 GUI 矩阵须继续验收。

依据：[libcurl SSH 认证方式](https://curl.se/libcurl/c/CURLOPT_SSH_AUTH_TYPES.html)、[Transmit SFTP 认证流程](https://help.panic.com/transmit/transmit5/sftp-faq/)、[OpenSSH 配置语义](https://man.openbsd.org/ssh_config.5)、[Include 条件恢复实现](https://github.com/openssh/openssh-portable/blob/master/readconf.c)。
