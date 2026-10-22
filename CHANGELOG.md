# Changelog

## [0.1.1] - 2026-10-22

- fix(credentials): "Save credentials in macOS Keychain" now defaults to on; turning it off removes stored secrets; connecting a bookmark without a stored password asks for it (with an option to save) instead of connecting with an empty password; Keychain read errors are shown instead of being treated as "no password".
- feat(drag): drop onto a folder row (list or icon view) to upload or download into that folder; drag remote files and folders into Finder or other apps through file promises that download via the transfer queue and hand over only verified files; local items are offered as copies; multi-row drags in list view; dropping on the remote side while disconnected explains that a connection is needed.
- feat(transfer): uploads, downloads and local copies take a target directory and resolve conflicts against that directory's listing; local copies run off the main thread and never copy a folder into itself.
- feat(queue): `TransferQueueManager.enqueue(onFinish:)` reports the first terminal state of each task.

## [0.1.0] - 2026-10-21

- feat(icon): redesign the app icon as a macOS-grid light plate with a blue folder and embossed upload / download arrows, rendered by `scripts/create_icon.swift` at 1024 px.
- fix(updater): publish `appcast.json` and the update ZIP as GitHub Release assets and point the default feed to `releases/latest/download/appcast.json`, keeping the GitHub Releases API fallback.
- feat(updater): add zero-dependency native In-App Online Updater (`AutoUpdater`, `SoftwareUpdateSheet`, `SemanticVersion`, `UpdateManifest`) supporting automatic/manual update checks, GitHub Releases API dual-channel fallback, streaming in-app download with live progress, SHA-256 + `codesign` verification, and atomic `.app` bundle replacement with immediate relaunch.
- feat(settings): add native macOS Settings window (`⌘,`, `SettingsView`) for dynamic max concurrency (1-10), default conflict resolution policy, default local folder, interface language, and automatic update checks.
- feat(tabs): add per-tab remote session and directory listing snapshot cache (`TabStateSnapshot`) for instant tab switching without re-listing or dropping active sessions.
- feat(i18n): add bilingual (`zh-Hans` / `en`) localization engine (`L10n`, `AppLanguage`) with system language detection, live language switching in menu bar, and VoiceOver accessibility labels.
- feat(throttle): wire `TransferQueueManager.speedLimitBytesPerSec` down to `CTransfer` (`at_set_speed_limit`, `CURLOPT_MAX_SEND_SPEED_LARGE`, `CURLOPT_MAX_RECV_SPEED_LARGE`) for real bandwidth throttling.
- feat(bookmarks): add in-place server bookmark editing (`ConnectionView` edit mode with Keychain credential prefill) alongside JSON export/import.
- feat(security): harden `Workspace.openTerminal` with `ShellEscape` single-quote and AppleScript escaping, embed Hardened Runtime `Entitlements.plist` (`com.apple.security.automation.apple-events`) and `NSAppleEventsUsageDescription`, and route recursive directory transfers through `ResumableTransfer`.
- feat(release): upgrade `scripts/build_app.sh` to generate `AppIcon.icns`, sign with Developer ID Application (Hardened Runtime + Entitlements), support automated `notarytool` + `stapler` notarization, and output `AetherTransfer-0.1.0-arm64.dmg`, `AetherTransfer-0.1.0-arm64.zip`, `SHA256SUMS.txt`, and `appcast.json`.
- feat(resume): add byte-range resumable transfers (`ResumableTransfer`, `ResumeTransferStore`, `LocalFileCommit`) with atomic Darwin `renamex_np`, SHA-256 fingerprinting, source/target tampering protection, and CTransfer `CURLOPT_RESUME_FROM_LARGE` windowed transfer support.
- feat(sync-nav): add Transmit-style synchronized browsing (`SyncNavigationManager`) to mirror directory navigation between local and remote panes.
- feat(archive): add Compress and Upload action (`ArchiveHelper`) to compress local selections into zip archives on the fly and upload directly.
- feat(queue): add queue pause and resume controls, and live macOS Dock badge counter.
- feat(sync): add Transmit-style directory synchronization and difference engine (`SyncEngine`, `SyncPlan`, `SyncSheet`) supporting local-to-remote, remote-to-local, bidirectional sync, rule customization, and safe-by-default orphan preservation.
- feat(preview): add spacebar Quick Look preview (`.quickLookPreview`, toolbar button, context menu) with automatic remote download caching.
- feat(drag-drop): add Finder and pane drag-and-drop support (`.dropDestination`, `.draggable`) for uploading and downloading files.
- feat(throttle): add bandwidth throttling and speed limiter presets (500 KB/s - 10 MB/s, Unlimited) in `TransferQueueManager` and Activity Queue Drawer.
- feat(bookmarks): add server bookmark backup and JSON interchange (`ServerProfile.exportJSON`, `ServerProfile.importJSON`).
- feat(tabs): add Transmit-style multi-tab workspace sessions (`TabSessionManager`, ⌘T, ⌘W) with independent local/remote paths and server connections.
- feat(permissions): add POSIX permissions parser, octal formatter, and interactive chmod editor in File Inspector.
- feat(rename): add Transmit-style batch renamer with text replace, prefix/suffix, sequence numbering rules, and live conflict detection.
- feat(editor): add built-in quick text/code editor (`QuickEditorSheet`) supporting viewing and remote save-back (⌘S).
- feat(terminal): add "Open in Terminal" action for both local directories and remote SSH server sessions.
- feat(transfer): add recursive directory upload and download support.
- feat(nav): add navigation history (back/forward) and interactive breadcrumb path bar.
- feat(conflict): implement conflict resolution strategy (overwrite, skip, keep both with auto-rename).
- feat(sort): support multi-column sorting (name, size, date, kind) and list/grid view switching.
- feat(profile): support server bookmark grouping and system Places navigation.
- feat(ui): align interface to macOS 26/27 Liquid Glass design specification with native materials, Transmit-style file inspector (⌘I), and real-time activity queue drawer.
- test: add 49 comprehensive TDD unit tests and 7 real FTP/SFTP protocol integration tests.
