import SwiftUI
import AppKit
import AetherTransferCore

// MARK: - Activity Queue Drawer
struct ActivityQueueDrawer: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("传输队列", "Activity Queue"))
                    .font(.headline)

                if workspace.activeTransferCount > 0 {
                    Text(L10n.tr("\(workspace.activeTransferCount) 个进行中", "\(workspace.activeTransferCount) Active"))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)

                    Text("⚡️ \(workspace.overallTransferSpeed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button(L10n.tr("不限速", "Unlimited")) { workspace.setSpeedLimit(nil) }
                    Divider()
                    Button("500 KB/s") { workspace.setSpeedLimit(500 * 1024) }
                    Button("1 MB/s") { workspace.setSpeedLimit(1024 * 1024) }
                    Button("2 MB/s") { workspace.setSpeedLimit(2 * 1024 * 1024) }
                    Button("5 MB/s") { workspace.setSpeedLimit(5 * 1024 * 1024) }
                    Button("10 MB/s") { workspace.setSpeedLimit(10 * 1024 * 1024) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: workspace.speedLimit == nil ? "gauge.with.needle" : "gauge.with.needle.fill")
                        Text(workspace.speedLimitText)
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)

                Button(action: { workspace.toggleQueuePause() }) {
                    Label(workspace.isQueuePaused ? L10n.tr("继续", "Resume") : L10n.tr("暂停", "Pause"),
                          systemImage: workspace.isQueuePaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .disabled(workspace.activeTransferCount == 0 && !workspace.isQueuePaused)
                .help(workspace.isQueuePaused ? L10n.tr("恢复传输队列", "Resume Queue") : L10n.tr("暂停传输队列", "Pause Queue"))

                Button(L10n.tr("清除已完成", "Clear Completed")) {
                    workspace.clearCompletedTransfers()
                }
                .buttonStyle(.borderless)
                .disabled(workspace.transferTasks.allSatisfy { $0.state != .completed })

                Button(L10n.tr("全部取消", "Cancel All")) {
                    workspace.cancelAllTransfers()
                }
                .buttonStyle(.borderless)
                .disabled(workspace.activeTransferCount == 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            if workspace.transferTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("无传输活动", "No Active Transfers"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workspace.transferTasks) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(item.direction == .upload ? Color.blue : Color.orange)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            if item.state == .inProgress {
                                HStack(spacing: 8) {
                                    ProgressView(value: item.progress)
                                        .frame(maxWidth: 180)
                                    if item.totalBytes > 0 {
                                        Text("\(ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    if item.speedBytesPerSec > 0 {
                                        Text(TransferQueueManager.formatSpeed(item.speedBytesPerSec))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if let err = item.error {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Text(item.state.localizedTitle)
                            .font(.caption)
                            .foregroundStyle(itemStateColor(item.state))

                        if item.state == .inProgress || item.state == .queued {
                            Button {
                                workspace.cancelTransfer(item.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("取消传输", "Cancel Transfer"))
                        } else if item.state == .failed || item.state == .cancelled {
                            Button {
                                workspace.retryTransfer(item.id)
                            } label: {
                                Image(systemName: "arrow.clockwise.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("重试传输", "Retry Transfer"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    private func itemStateColor(_ state: TransferState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .inProgress: return .accentColor
        case .queued: return .secondary
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Menu Bar Quick Upload Droplet (Transmit Droplet Parity)
struct MenuBarDropletView: View {
    @ObservedObject var workspace: Workspace
    @State private var targetedProfileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AetherTransfer", systemImage: "bolt.horizontal.circle.fill")
                    .font(.headline)
                Spacer()
                if workspace.activeTransferCount > 0 {
                    Text("\(workspace.activeTransferCount) · \(workspace.overallTransferSpeed)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(L10n.tr("将访达文件拖拽至下方服务器即可后台闪电上传：",
                         "Drop files from Finder onto any server below for instant upload:"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if workspace.profiles.isEmpty {
                Text(L10n.tr("暂无已保存的服务器书签", "No saved server bookmarks yet"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(workspace.profiles) { profile in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.doc.fill")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name.isEmpty ? profile.host : profile.name)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Text("\(profile.protocolKind.title) · \(profile.initialPath)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(L10n.tr("选择文件", "Upload…")) {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = true
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = true
                                    if panel.runModal() == .OK {
                                        workspace.uploadDroppedURLs(panel.urls, to: profile)
                                    }
                                }
                                .controlSize(.mini)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(targetedProfileId == profile.id ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                            )
                            .dropDestination(for: URL.self) { urls, _ in
                                workspace.uploadDroppedURLs(urls, to: profile)
                                return true
                            } isTargeted: { targeted in
                                targetedProfileId = targeted ? profile.id : (targetedProfileId == profile.id ? nil : targetedProfileId)
                            }
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            Divider()

            HStack {
                Button(L10n.tr("打开主窗口", "Open Main Window")) {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
                Spacer()
                Button(L10n.tr("退出", "Quit")) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 310)
    }
}
