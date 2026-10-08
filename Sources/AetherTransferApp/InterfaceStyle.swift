import SwiftUI
import AppKit
import AetherTransferCore

/// Shared measurements for chrome and forms. Native lists keep reusable rows.
enum InterfaceStyle {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 16
    static let fieldGap: CGFloat = 12
    static let fieldLabelWidth: CGFloat = 150
    static let fieldMinimumWidth: CGFloat = 250
    static let connectionWidth: CGFloat = 600
    static let connectionHeight: CGFloat = 640
    static let recoveryWidth: CGFloat = 760
    static let syncWidth: CGFloat = 1020
    static let actionMinimumHeight: CGFloat = 32
    static let statusMinimumHeight: CGFloat = 36
    static let groupInset: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    static let listRowHeight: CGFloat = 28
    static let columnWidth: CGFloat = 260
    static let paneInset: CGFloat = 12
    static let fileSymbolSize: CGFloat = 14
    static let tabTransition: Double = 0.18
}

/// A fixed action area shared by sheets. The scrolling body owns its height;
/// language changes can wrap labels without moving the actions offscreen.
struct SheetActions<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: InterfaceStyle.fieldGap) { content }
            .frame(minHeight: InterfaceStyle.actionMinimumHeight)
            .padding(InterfaceStyle.pageInset)
    }
}

/// Explicit columns avoid platform-dependent LabeledContent spacing. Keep the
/// native field's own accessibility label and its full editable hit area.
struct FormFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceStyle.fieldGap) {
            Text(verbatim: title)
                .frame(width: InterfaceStyle.fieldLabelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            content.textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                .frame(minWidth: InterfaceStyle.fieldMinimumWidth, maxWidth: .infinity)
        }
    }
}

/// Supporting copy must wrap in English as well as Chinese, including inside
/// horizontal stacks. No fixed line limit or faded opacity is applied.
struct SupportingText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct InterfaceMessage: View {
    enum Severity { case error, warning }
    let text: String
    var severity: Severity = .error
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity == .error ? "exclamationmark.circle" : "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }.font(.callout).foregroundStyle(severity == .error ? Color.red : Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InterfaceStatusBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .font(.caption).foregroundStyle(.secondary)
            .frame(minHeight: InterfaceStyle.statusMinimumHeight)
            .padding(.horizontal, InterfaceStyle.paneInset)
    }
}

enum DisplayFormat {
    static func bytes(_ value: Int64, style: ByteCountFormatStyle.Style = .file) -> String {
        ByteCountFormatStyle(style: style, spellsOutZero: false, locale: AppLanguage.current.locale).format(value)
    }
}

struct SheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var inset: CGFloat = InterfaceStyle.pageInset
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 25, weight: .medium))
                .foregroundStyle(.tint).frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(inset)
    }
}

/// Separately hosted editor windows keep language and appearance without
/// recreating the editor or discarding its unsaved draft.
struct AppPresentation: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    func body(content: Content) -> some View {
        content
            .environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
            .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    }
}

/// Settings uses an AppKit window title; changing only SwiftUI's Locale does
/// not update the title supplied by the system Settings scene.
struct InterfaceWindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TitleView {
        let view = TitleView(frame: .zero)
        view.title = title
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
        view.updateTitle()
    }
    final class TitleView: NSView {
        var title = ""
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTitle() }
        func updateTitle() {
            if let window, window.title != title { window.title = title }
        }
    }
}
