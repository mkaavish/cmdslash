import Foundation
import PDFKit

/// The `read_file` tool (Docs/PLANNING.md §21). Extracts text from plain-text/code files and
/// PDFs — this is the tool that actually sends file content to the model (as a tool_result in the
/// agentic loop, §29), which makes it the real data-exfiltration point `SensitivePathGuard`
/// (§34) exists to protect.
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
        try SensitivePathGuard.assertAllowed(path)

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
