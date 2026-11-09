import BackgroundMemoCore
import Foundation

/// Keeps the NEIS API key in an owner-only file under Application Support.
/// The keychain is not used because this app is ad-hoc signed: each rebuild changes its identity,
/// and the resulting system password prompt blocks the launch.
@MainActor
final class NEISKeyStore {
    private let file: URL
    private var cachedKey: String?
    private var hasRead = false

    init(paths: AppPaths) {
        file = paths.root.appendingPathComponent("neis-api-key")
    }

    var key: String? {
        if !hasRead {
            hasRead = true
            cachedKey = read()
        }
        return cachedKey
    }

    func save(_ newKey: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".neis-api-key.\(UUID().uuidString)")
        guard manager.createFile(
            atPath: temporary.path,
            contents: Data(newKey.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, file.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        cachedKey = newKey
        hasRead = true
    }

    func delete() throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
        cachedKey = nil
        hasRead = true
    }

    private func read() -> String? {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
