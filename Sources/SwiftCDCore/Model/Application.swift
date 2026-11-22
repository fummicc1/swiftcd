import Foundation

/// ArgoCDの `Application` に相当する、同期対象の定義。
public struct Application: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var repoURL: String
        public var path: String
        public var targetRevision: String

        public init(repoURL: String, path: String = ".", targetRevision: String = "HEAD") {
            self.repoURL = repoURL
            self.path = path
            self.targetRevision = targetRevision
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            repoURL = try container.decode(String.self, forKey: .repoURL)
            path = try container.decodeIfPresent(String.self, forKey: .path) ?? "."
            targetRevision = try container.decodeIfPresent(String.self, forKey: .targetRevision) ?? "HEAD"
        }
    }

    public struct Destination: Codable, Sendable, Equatable {
        public var namespace: String

        public init(namespace: String) {
            self.namespace = namespace
        }
    }

    public struct SyncPolicy: Codable, Sendable, Equatable {
        public var automated: Bool
        /// Gitから消えたリソースを、Syncのたびにクラスタからも削除する。
        public var prune: Bool

        public init(automated: Bool = false, prune: Bool = false) {
            self.automated = automated
            self.prune = prune
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            automated = try container.decodeIfPresent(Bool.self, forKey: .automated) ?? false
            prune = try container.decodeIfPresent(Bool.self, forKey: .prune) ?? false
        }
    }

    public var name: String
    public var source: Source
    public var destination: Destination
    public var syncPolicy: SyncPolicy

    public init(name: String, source: Source, destination: Destination, syncPolicy: SyncPolicy = .init()) {
        self.name = name
        self.source = source
        self.destination = destination
        self.syncPolicy = syncPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(Source.self, forKey: .source)
        destination = try container.decode(Destination.self, forKey: .destination)
        syncPolicy = try container.decodeIfPresent(SyncPolicy.self, forKey: .syncPolicy) ?? .init()
    }
}

public enum SyncStatus: String, Codable, Sendable {
    case synced = "Synced"
    case outOfSync = "OutOfSync"
    case unknown = "Unknown"
}

/// 値が大きいほど悪い状態。アプリ全体のヘルスは最も悪いリソースに合わせる。
public enum HealthStatus: String, Codable, Sendable, Comparable {
    case healthy = "Healthy"
    case progressing = "Progressing"
    case missing = "Missing"
    case degraded = "Degraded"
    case unknown = "Unknown"

    private var severity: Int {
        switch self {
        case .healthy: 0
        case .progressing: 1
        case .missing: 2
        case .degraded: 3
        case .unknown: 4
        }
    }

    public static func < (lhs: HealthStatus, rhs: HealthStatus) -> Bool {
        lhs.severity < rhs.severity
    }
}

public struct ResourceRef: Codable, Sendable, Hashable {
    public var group: String
    public var kind: String
    public var name: String

    public init(group: String, kind: String, name: String) {
        self.group = group
        self.kind = kind
        self.name = name
    }

    /// `apps/v1` → `apps`、`v1` → `""`（core group）
    public init(apiVersion: String, kind: String, name: String) {
        let parts = apiVersion.split(separator: "/")
        self.init(group: parts.count == 2 ? String(parts[0]) : "", kind: kind, name: name)
    }
}

public struct ResourceStatus: Codable, Sendable, Equatable {
    public var ref: ResourceRef
    public var sync: SyncStatus
    public var health: HealthStatus
    public var message: String?
    /// Gitにはもう無いが、クラスタに残っている管理対象リソース。
    public var requiresPruning: Bool

    public init(ref: ResourceRef, sync: SyncStatus, health: HealthStatus, message: String? = nil, requiresPruning: Bool = false) {
        self.ref = ref
        self.sync = sync
        self.health = health
        self.message = message
        self.requiresPruning = requiresPruning
    }
}

public enum OperationPhase: String, Codable, Sendable {
    case idle = "Idle"
    case refreshing = "Refreshing"
    case syncing = "Syncing"
}

public struct AppStatus: Codable, Sendable, Equatable {
    public var name: String
    public var source: Application.Source
    public var destination: Application.Destination
    public var automated: Bool
    public var prune: Bool
    public var phase: OperationPhase
    public var sync: SyncStatus
    public var health: HealthStatus
    public var revision: String?
    public var revisionMessage: String?
    public var resources: [ResourceStatus]
    public var lastReconciledAt: Date?
    public var lastSyncedAt: Date?
    public var lastSyncedRevision: String?
    public var error: String?

    public init(app: Application) {
        name = app.name
        source = app.source
        destination = app.destination
        automated = app.syncPolicy.automated
        prune = app.syncPolicy.prune
        phase = .idle
        sync = .unknown
        health = .unknown
        resources = []
    }
}
