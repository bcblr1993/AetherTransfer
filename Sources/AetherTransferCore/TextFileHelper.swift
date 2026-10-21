import Foundation

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
}
