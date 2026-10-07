import Foundation

public enum FileSortField: Sendable, Hashable { case name, size, modified }

/// Filtering and ordering can run on a worker without capturing SwiftUI comparators.
public enum FilePresentation {
    public static func entries(_ files: [FileEntry], query: String, showHidden: Bool,
                               field: FileSortField = .name, descending: Bool = false) -> [FileEntry] {
        files.filter { (showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { lhs, rhs in
                let result: ComparisonResult
                switch field {
                case .name: result = lhs.name.localizedStandardCompare(rhs.name)
                case .size:
                    result = lhs.size == rhs.size ? lhs.name.localizedStandardCompare(rhs.name) : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
                case .modified:
                    result = lhs.modifiedSortValue == rhs.modifiedSortValue ? lhs.name.localizedStandardCompare(rhs.name) : (lhs.modifiedSortValue < rhs.modifiedSortValue ? .orderedAscending : .orderedDescending)
                }
                return result == (descending ? .orderedDescending : .orderedAscending)
            }
    }
}
