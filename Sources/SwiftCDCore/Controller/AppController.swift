import Foundation

/// アプリ1つ分のreconcileループ。ArgoCDのapplication-controllerに相当する。
public actor AppController {
    public let app: Application
    private let git: GitClient
    private let cluster: ClusterClient
    private let workDirectory: URL
    private let interval: Duration
    private let now: @Sendable () -> Date

    public private(set) var status: AppStatus
    private var loopTask: Task<Void, Never>?
    /// refreshとsyncが同時に走らないよう、操作を1本の列に並べる。
    private var lastOperation: Task<Void, Never>?

    public init(
        app: Application,
        git: GitClient,
        cluster: ClusterClient,
        workDirectory: URL,
        interval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.app = app
        self.git = git
        self.cluster = cluster
        self.workDirectory = workDirectory
        self.interval = interval
        self.now = now
        self.status = AppStatus(app: app)
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [interval] in
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Gitとクラスタの状態を比べてステータスを更新する。automatedなら新しいリビジョンを自動Syncする。
    @discardableResult
    public func refresh() async -> AppStatus {
        await enqueue { await self.performRefresh(allowAutoSync: true) }
        return status
    }

    /// 手動Sync。
    @discardableResult
    public func sync() async -> AppStatus {
        await enqueue { await self.performSync() }
        return status
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = lastOperation
        let task = Task {
            await previous?.value
            await operation()
        }
        lastOperation = task
        await task.value
    }

    private var repoDirectory: URL { workDirectory.appendingPathComponent("repo") }
    private var renderedFile: URL { workDirectory.appendingPathComponent("rendered.json") }

    private func fetchAndRender() async throws -> (GitRevision, RenderedManifests) {
        let revision = try await git.checkout(
            repoURL: app.source.repoURL, revision: app.source.targetRevision, into: repoDirectory)
        let manifests = try ManifestRenderer.render(
            sourceDirectory: repoDirectory.appendingPathComponent(app.source.path),
            appName: app.name,
            output: renderedFile)
        return (revision, manifests)
    }

    private func performRefresh(allowAutoSync: Bool) async {
        status.phase = .refreshing
        defer { status.phase = .idle }
        do {
            let (revision, manifests) = try await fetchAndRender()
            try await compare(revision: revision, manifests: manifests)

            // ArgoCDと同じく、自動Syncは「まだSyncしていないリビジョン」に対してだけ行う。
            // 手動の変更（ドリフト）はOutOfSyncとして表示するだけで、戻さない（self-healは未対応）。
            if allowAutoSync, app.syncPolicy.automated, status.sync == .outOfSync,
               status.lastSyncedRevision != revision.sha {
                try await apply(revision: revision, manifests: manifests)
            }
        } catch {
            status.error = "\(error)"
            status.sync = .unknown
            status.lastReconciledAt = now()
        }
    }

    private func performSync() async {
        status.phase = .syncing
        defer { status.phase = .idle }
        do {
            let (revision, manifests) = try await fetchAndRender()
            try await apply(revision: revision, manifests: manifests)
        } catch {
            status.error = "\(error)"
            status.lastReconciledAt = now()
        }
    }

    private func apply(revision: GitRevision, manifests: RenderedManifests) async throws {
        status.phase = .syncing
        try await cluster.ensureNamespace(app.destination.namespace)
        _ = try await cluster.apply(manifests, namespace: app.destination.namespace)
        status.lastSyncedAt = now()
        status.lastSyncedRevision = revision.sha
        try await compare(revision: revision, manifests: manifests)
    }

    private func compare(revision: GitRevision, manifests: RenderedManifests) async throws {
        let namespace = app.destination.namespace
        let diff: DiffResult
        let live: [LiveObject]
        if try await cluster.namespaceExists(namespace) {
            diff = try await cluster.diff(manifests, namespace: namespace)
            live = try await cluster.liveObjects(manifests, namespace: namespace)
        } else {
            // namespaceが無いとサーバーサイドのdiffが失敗するので、全リソース未作成として扱う。
            diff = DiffResult(outOfSync: Set(manifests.resources), hasDiff: !manifests.resources.isEmpty)
            live = []
        }

        let liveByRef = Dictionary(live.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let resources = manifests.resources.map { ref -> ResourceStatus in
            let health = liveByRef[ref].map(HealthAssessor.assess) ?? HealthResult(.missing)
            let sync: SyncStatus = diff.outOfSync.contains(ref) || liveByRef[ref] == nil ? .outOfSync : .synced
            return ResourceStatus(ref: ref, sync: sync, health: health.status, message: health.message)
        }

        status.revision = revision.sha
        status.revisionMessage = revision.message
        status.resources = resources
        status.sync = diff.hasDiff || resources.contains { $0.sync == .outOfSync } ? .outOfSync : .synced
        status.health = HealthAssessor.aggregate(resources.map(\.health))
        status.error = nil
        status.lastReconciledAt = now()
    }
}
