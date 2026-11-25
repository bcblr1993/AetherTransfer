import Foundation

public enum TextFileEncodingError: LocalizedError, Sendable, Equatable {
    case decodingFailed(TextFileEncoding)
    case encodingFailed(TextFileEncoding)

    public var errorDescription: String? {
        switch self {
        case .decodingFailed(let encoding):
            return L10n.tr(
                "无法使用 \(encoding.localizedTitle) 解码文本数据。",
                "Unable to decode text data using \(encoding.localizedTitle)."
            )
        case .encodingFailed(let encoding):
            return L10n.tr(
                "无法使用 \(encoding.localizedTitle) 编码文本内容。",
                "Unable to encode text using \(encoding.localizedTitle)."
            )
        }
    }
}

public enum TextFileHelper {
    public static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "json", "xml", "html", "htm", "css", "js", "ts",
        "swift", "c", "h", "cpp", "hpp", "m", "mm", "py", "sh", "bash", "zsh", "yaml", "yml",
        "toml", "conf", "config", "ini", "env", "log", "sql", "csv", "tsv", "rs", "go", "java", "kt"
    ]

    public static func isTextFileName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            let lower = name.lowercased()
            return lower == "dockerfile" || lower == "makefile" || lower == "license" || lower == "readme"
        }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return textExtensions.contains(ext)
    }

    public static func isProbablyTextData(_ data: Data) -> Bool {
        let sample = data.prefix(1024)
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    public static func decodeText(_ data: Data, encoding: TextFileEncoding) throws -> String {
        if data.isEmpty { return "" }
        guard let decoded = String(data: data, encoding: encoding.stringEncoding) else {
            throw TextFileEncodingError.decodingFailed(encoding)
        }
        return decoded
    }

    public static func encodeText(_ text: String, encoding: TextFileEncoding) throws -> Data {
        guard let encoded = text.data(using: encoding.stringEncoding, allowLossyConversion: false) else {
            throw TextFileEncodingError.encodingFailed(encoding)
        }
        return encoded
    }

    public static func lineAndColumnCounts(_ text: String) -> (lines: Int, characters: Int) {
        let characterCount = text.count
        var lineCount = 0
        text.enumerateLines { _, _ in
            lineCount += 1
        }
        return (lines: lineCount, characters: characterCount)
    }
}
