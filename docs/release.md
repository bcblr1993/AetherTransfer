# 发布流程

正式发布必须依次完成下列步骤；任一步失败都不得发布或在官网标注“已公证”。

1. 门禁：`swift test`、`scripts/test_protocols.sh`（真实 FTP / SFTP）、运行 `.app` 检查主要窗口。
2. 一次性配置公证凭据（需 Apple ID 的 App 专用密码，由维护者本人执行）：
   `xcrun notarytool store-credentials AetherTransfer --apple-id <Apple ID> --team-id 5984KQD4D7`
3. 打包：`NOTARY_PROFILE=AetherTransfer VERSION=0.1.0 BUILD_NUMBER=<构建号> scripts/build_app.sh`。
   产物在 `outputs/`：DMG、ZIP、`SHA256SUMS.txt`、`appcast.json`。
4. 验证：`spctl -a -vvv -t install outputs/AetherTransfer-<版本>-arm64.dmg` 显示 `Notarized Developer ID`，
   `xcrun stapler validate` 通过，`shasum -a 256 -c outputs/SHA256SUMS.txt` 通过。
5. 合并到 `main`，打标签 `v<版本>` 并推送。
6. 创建 GitHub Release：正文用 `docs/release-notes/v<版本>.md`（把 `BUILD_NUMBER` 换成实际构建号），
   附件上传 DMG、ZIP、`SHA256SUMS.txt`、`appcast.json`。应用内更新读取
   `releases/latest/download/appcast.json`，因此四个附件缺一不可。
7. Release 发布后，`aethernative-sync.yml` 通知官网写入 `releases.yaml`（需仓库 Secret `AETHERNATIVE_SITE_TOKEN`）。
8. 产品页文案：`scripts/sync_to_website.sh ../aethernative-site`，在官网仓库运行 `npm run build` 后只提交
   `src/content/apps/aethertransfer/`。
9. 公开验证：从官网和 GitHub 下载 DMG，核对 SHA-256，在干净账户中安装启动；在旧版本中检查更新可发现新版本。
