import Foundation

/// Application定義が変わったら保存済みの記録を無視できるよう、Sync時点の定義も一緒に保存する。
struct SyncState: Codable, Equatable {
    var app: Application
    var lastSyncedRevision: String
    var lastSyncedAt: Date

    static func load(from file: URL) -> SyncState? {
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }
        return try? APICoding.decoder.decode(SyncState.self, from: data)
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try APICoding.encoder.encode(self).write(to: file, options: .atomic)
    }
}
