import SwiftUI
import AetherTransferCore

/// Shared measurements for chrome and forms. Native lists keep reusable rows.
enum InterfaceStyle {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 16
    static let fieldGap: CGFloat = 12
    static let fieldLabelWidth: CGFloat = 150
    static let connectionWidth: CGFloat = 600
    static let listRowHeight: CGFloat = 28
    static let tabTransition: Double = 0.18
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
