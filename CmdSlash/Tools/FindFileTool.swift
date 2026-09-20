import AppKit
import Foundation

/// The `find_file` tool (Docs/PLANNING.md §21). Tries Spotlight (`NSMetadataQuery`) first — the
/// structured, indexed mechanism per §14 — then falls back to a direct filesystem search of the
/// common locations if Spotlight comes up empty. That fallback exists because Spotlight's index
/// can be stale or mid-reindex (confirmed on-device via `mdfind`/`mdutil`: indexing reported
/// "enabled" with mdbulkimport actively running, yet a wildcard query returned zero results for
/// the entire home directory) — without it, this tool would fail on files that plainly exist
/// whenever the index hasn't caught up, which isn't a hypothetical edge case.
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
        var matches = await spotlightSearch(query: query, kind: kind)
        if matches.isEmpty {
            matches = filesystemFallbackSearch(query: query, kind: kind)
        }

        // Filtered regardless of which search found them — credential-path matches shouldn't
        // even surface as results or get revealed in Finder (Docs/PLANNING.md §34).
        let allowed = Array(matches.filter { !SensitivePathGuard.isBlocked($0.path) }.prefix(5))

        guard !allowed.isEmpty else {
            throw ToolError.noMatches(query)
        }

        if let topPath = allowed.first?.path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: topPath)])
        }

        return allowed
    }

    private func spotlightSearch(query: String, kind: String?) async -> [Match] {
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

        return await withCheckedContinuation { continuation in
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
                continuation.resume(returning: results)
            }

            DispatchQueue.main.async {
                metadataQuery.start()
            }
        }
    }

    /// Bounded to the common download/save locations rather than the whole home directory — fast
    /// and covers the actual demo case ("find the PDF I downloaded yesterday") without a
    /// potentially slow full-tree walk. Kind matching here is a plain extension comparison, not
    /// Spotlight's richer category matching (e.g. "image" won't match "jpg") — an acceptable gap
    /// for a fallback path, not the primary mechanism.
    private func filesystemFallbackSearch(query: String, kind: String?) -> [Match] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let searchRoots = ["Downloads", "Desktop", "Documents"].map { home.appendingPathComponent($0) }
        let lowercasedQuery = query.lowercased()
        let lowercasedKind = kind?.lowercased()

        var results: [Match] = []
        for root in searchRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
                guard url.lastPathComponent.lowercased().contains(lowercasedQuery) else { continue }
                if let lowercasedKind, !url.pathExtension.lowercased().isEmpty {
                    guard url.pathExtension.lowercased() == lowercasedKind else { continue }
                }
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                results.append(Match(path: url.path, name: url.lastPathComponent, modifiedAt: modifiedAt))
            }
        }

        return results.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }
}
