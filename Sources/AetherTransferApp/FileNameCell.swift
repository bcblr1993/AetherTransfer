import AppKit
import AetherTransferCore

/// Shared reusable name rows for list and column presentations.
@MainActor final class FileNameCell: NSTableCellView {
    private let disclosure: NSImageView?
    init(identifier: NSUserInterfaceItemIdentifier, showsDisclosure: Bool = false) {
        disclosure = showsDisclosure ? NSImageView() : nil
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = InterfaceStyle.listFont
        text.textColor = .labelColor; text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text); textField = text
        let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: InterfaceStyle.fileSymbolSize, weight: .regular)
        addSubview(icon); imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if let disclosure {
            disclosure.translatesAutoresizingMaskIntoConstraints = false
            disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            disclosure.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            disclosure.contentTintColor = .tertiaryLabelColor
            disclosure.setAccessibilityElement(false)
            addSubview(disclosure)
            NSLayoutConstraint.activate([
                disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                disclosure.centerYAnchor.constraint(equalTo: centerYAnchor), disclosure.widthAnchor.constraint(equalToConstant: 10),
                text.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -6)
            ])
        } else { text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ entry: FileEntry) {
        textField?.stringValue = entry.name
        imageView?.image = NSImage(systemSymbolName: Self.symbol(entry), accessibilityDescription: entry.isDirectory ? L10n.text("文件夹") : L10n.text("文件"))
        imageView?.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
        disclosure?.isHidden = !entry.isDirectory
        toolTip = entry.name
    }
    private static func symbol(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isSymbolicLink { return "link" }
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "mkv": return "film"
        case "mp3", "flac", "m4a", "wav": return "music.note"
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "swift", "js", "ts", "py", "json", "yaml", "yml", "html", "css": return "curlybraces"
        default: return "doc"
        }
    }
}
