# UI 与性能验收

用户要求：UI 好看、动画漂亮、本机性能好。此要求与完整 Transmit 功能目标并行，不能用视觉效果替代真实协议能力。

界面采用系统 NavigationSplitView、工具栏、原生弹窗和固定行高的 AppKit NSTableView。文件内容保持清晰；玻璃集中于操作控件和标签。标签使用 GlassEffectContainer 与 matchedGeometry，约 250 ms；活动面板展开约 250 ms。系统“减少动态效果”开启时取消这些动画。文件列表不继承标签动画，不创建每行玻璃或持续装饰动效。

文件元数据读取、远程目录解析、筛选与排序在 worker 执行。查询有 120 ms 去抖，过时请求不能回写。列表通过稳定数据版本控制 reloadData，固定行高、复用单元格和日期/字节格式化器；进度约 10 Hz 更新。传输并发和速率有界。

本机记录（2026-10-07，Apple M1 Max，64 GB，macOS 27.0.1，release 构建；每项 5 次、中位数，缓存与系统负载会影响结果）：

| 场景 | 数量 | 中位耗时 |
| --- | ---: | ---: |
| LIST 解析，包含中文、空格、日期 | 10,000 条 | 78.81 ms |
| 自然名称排序 | 10,000 条 | 5.90 ms |
| 名称筛选并按大小排序 | 10,000 条 | 12.61 ms |
| 本地元数据与自然排序 | 5,000 项 | 75.18 ms |

同机日期解析优化前的 LIST 解析中位数为 658.41 ms。上表只度量 Core 操作，不包含网络等待、界面布局或磁盘冷缓存，不能称为端到端速度。

真实 UI 已回归：1 万个文件载入；创建/切换标签；筛选最后一个文件；清空筛选、切换到小目录；打开设置。此前 SwiftUI Table 在这一组合路径进入持续更新，采样峰值约 2.2 GiB physical footprint；改用 AppKit 复用表格后此路径可正常完成。回归后 5 秒空闲采样为 0.20% 单核 CPU、227.73 MiB RSS；RSS 与 physical footprint 不能混用。原生表格的 SFTP 上传/下载也通过界面完成并核对字节一致；浅色/深色窗口已检查。

可复现基准：`swift run -c release AetherTransferBenchmarks`。工具只在自己的临时目录创建并清理 5,000 个零字节文件；不读取用户目录。真实 UI 证据在忽略的 reports/，不提交用户路径或系统全进程跟踪数据。

当前性能目标：大目录交互后的空闲 CPU < 1% 单核、RSS < 300 MiB；自然排序/筛选 < 30 ms；1 万条 LIST 解析 < 150 ms。这些是开发门槛，需要扩展到更多机型与 macOS 26，尚不是发布承诺。仍待验收：长时运行、并发大文件传输、内存泄漏、能耗、动画 hitches、VoiceOver 和减少透明度。

实现依据：[Apple Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[AppKit view reuse](https://developer.apple.com/documentation/appkit/nstableview/makeview(withidentifier:owner:))。
