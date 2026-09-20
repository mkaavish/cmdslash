import AppKit
import Foundation

/// The `find_file` tool (Docs/PLANNING.md §21). Uses Spotlight (`NSMetadataQuery`) rather than
/// walking the filesystem — the structured, indexed mechanism per §14. Scoped to the user's home
/// directory by default (fast, and covers the common case) rather than the whole computer.
struct FindFileTool {
    struct Match {
        let path: String
        let name: String
        let modifiedAt: Date?
    }

    enum ToolError: Error, LocalizedError {
        case noMatches(String)

        var errorDescription: String? {
            switch self {
            case .noMatches(let query):
                "No files found matching \"\(query)\"."
            }
        }
    }

    /// Reveals the best (most recently modified) match in Finder — "find X" implies wanting to
    /// see or access it, so this tool's real-world action is the reveal, not just the search.
    @discardableResult
    func execute(query: String, kind: String? = nil) async throws -> [Match] {
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryUserHomeScope]

        var predicateFormat = "kMDItemFSName CONTAINS[cd] %@"
        var args: [Any] = [query]
        if let kind, !kind.isEmpty {
            predicateFormat += " AND kMDItemKind CONTAINS[cd] %@"
            args.append(kind)
        }
        metadataQuery.predicate = NSPredicate(format: predicateFormat, argumentArray: args)
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        let matches: [Match] = await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                metadataQuery.stop()
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }

                let results: [Match] = metadataQuery.results.compactMap { item in
                    guard
                        let metadataItem = item as? NSMetadataItem,
                        let path = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String
                    else {
                        return nil
                    }
                    let name = (metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                        ?? (path as NSString).lastPathComponent
                    let modifiedAt = metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
                    return Match(path: path, name: name, modifiedAt: modifiedAt)
                }
                continuation.resume(returning: Array(results.prefix(5)))
            }

            DispatchQueue.main.async {
                metadataQuery.start()
            }
        }

        guard !matches.isEmpty else {
            throw ToolError.noMatches(query)
        }

        if let topPath = matches.first?.path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: topPath)])
        }

        return matches
    }
}
