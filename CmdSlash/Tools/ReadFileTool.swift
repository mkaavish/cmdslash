import Foundation
import PDFKit

/// The `read_file` tool (Docs/PLANNING.md §21). Extracts text from plain-text/code files and
/// PDFs. Its output isn't meant for the current one-line status UI to display directly — it's
/// meant to feed a later step (summarize, explain), which needs the real multi-step planner
/// (§20, §29) that doesn't exist yet. For now this only proves the extraction primitive works.
struct ReadFileTool {
    struct Result {
        let path: String
        let fileName: String
        let content: String
        let truncated: Bool
    }

    enum ToolError: Error, LocalizedError {
        case fileNotFound(String)
        case unsupportedType(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                "No file found at \(path)."
            case .unsupportedType(let ext):
                "Don't know how to read .\(ext) files yet."
            case .readFailed(let path):
                "Couldn't read \(path)."
            }
        }
    }

    private static let maxCharacters = 4000
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "json", "csv", "log", "yml", "yaml", "xml", "html", "js", "ts", "py"
    ]

    func execute(path: String) throws -> Result {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ToolError.fileNotFound(path)
        }
        let url = URL(fileURLWithPath: expandedPath)
        let ext = url.pathExtension.lowercased()

        let fullText: String
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw ToolError.readFailed(path)
            }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                if let page = document.page(at: index), let text = page.string {
                    pages.append(text)
                }
            }
            fullText = pages.joined(separator: "\n")
        } else if Self.textExtensions.contains(ext) || ext.isEmpty {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError.readFailed(path)
            }
            fullText = text
        } else {
            throw ToolError.unsupportedType(ext)
        }

        let truncated = fullText.count > Self.maxCharacters
        let content = truncated ? String(fullText.prefix(Self.maxCharacters)) : fullText
        return Result(path: expandedPath, fileName: url.lastPathComponent, content: content, truncated: truncated)
    }
}
