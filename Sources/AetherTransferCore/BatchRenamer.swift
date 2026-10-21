import Foundation

public enum RenameRule: Sendable {
    case replace(find: String, replaceWith: String)
    case addPrefix(String)
    case addSuffix(String)
    case sequence(format: String, start: Int, padding: Int)
}

public struct RenameItemPlan: Identifiable, Sendable {
    public var id: String { originalName }
    public let originalName: String
    public let newName: String
    public let hasError: Bool
    public let errorDescription: String?

    public init(originalName: String, newName: String, hasError: Bool = false, errorDescription: String? = nil) {
        self.originalName = originalName
        self.newName = newName
        self.hasError = hasError
        self.errorDescription = errorDescription
    }
}

public struct BatchRenamer: Sendable {
    public let rule: RenameRule

    public init(rule: RenameRule) {
        self.rule = rule
    }

    public func plan(for originalNames: [String]) -> [RenameItemPlan] {
        var rawNewNames: [String] = []

        for (index, name) in originalNames.enumerated() {
            let dotIndex = name.lastIndex(of: ".")
            let base: String
            let ext: String
            if let dot = dotIndex, dot != name.startIndex {
                base = String(name[..<dot])
                ext = String(name[dot...])
            } else {
                base = name
                ext = ""
            }

            let newName: String
            switch rule {
            case .replace(let find, let replaceWith):
                newName = name.replacingOccurrences(of: find, with: replaceWith)
            case .addPrefix(let prefix):
                newName = prefix + name
            case .addSuffix(let suffix):
                newName = base + suffix + ext
            case .sequence(let format, let start, let padding):
                let number = start + index
                let numStr = String(format: "%0\(padding)d", number)
                let formatted = format.replacingOccurrences(of: "{N}", with: numStr)
                newName = formatted + ext
            }
            rawNewNames.append(newName)
        }

        // Count occurrences to detect collisions
        var counts: [String: Int] = [:]
        for n in rawNewNames {
            counts[n, default: 0] += 1
        }

        var results: [RenameItemPlan] = []
        for (i, orig) in originalNames.enumerated() {
            let target = rawNewNames[i]
            let isCollision = (counts[target] ?? 0) > 1
            results.append(RenameItemPlan(
                originalName: orig,
                newName: target,
                hasError: isCollision,
                errorDescription: isCollision ? "名称冲突" : nil
            ))
        }
        return results
    }
}
