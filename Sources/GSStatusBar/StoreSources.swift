#if APP_STORE
import Foundation
import UsageCore

/// Keeps the folder readable while either the watcher or an in-flight refresh uses it.
final class StoreCodexFolder: Sendable {
    let url: URL

    private init(url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        self.url = url
    }

    deinit { url.stopAccessingSecurityScopedResource() }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) throws -> (folder: StoreCodexFolder, bookmark: Data) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let folder = try StoreCodexFolder(url: url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (folder, stale ? try bookmark(for: url) : data)
    }
}

enum StoreClaudeReport {
    /// The caller passes the URL received from the open panel, which starts security-scoped access.
    static func readSelectedFile(_ url: URL) throws -> UsageSnapshot {
        defer { url.stopAccessingSecurityScopedResource() }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }

        let maximumBytes = 2 * 1024 * 1024
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw ImportError.tooLarge
        }
        guard let report = ClaudeUsageText.parseImportedReport(data, fallbackDate: values.contentModificationDate ?? Date()) else {
            throw ImportError.invalidReport
        }
        return UsageSnapshot(provider: .claude, windows: report.windows, observedAt: report.observedAt,
                             source: "Imported Claude usage report", plan: report.plan)
    }

    private enum ImportError: LocalizedError {
        case tooLarge
        case invalidReport

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose a Claude usage report that is 2 MB or smaller."
            case .invalidReport: "No usage limits found. Choose a Claude Code usage report in text, JSON, or JSONL format."
            }
        }
    }
}
#endif
