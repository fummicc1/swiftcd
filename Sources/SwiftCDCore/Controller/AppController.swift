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
        var status = AppStatus(app: app)
        if let state = SyncState.load(from: Self.stateFile(in: workDirectory)), state.app == app {
            status.lastSyncedRevision = state.lastSyncedRevision
            status.lastSyncedAt = state.lastSyncedAt
        }
        self.status = status
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

    /// 手動Sync。`prune` がfalseでも、Applicationの `syncPolicy.prune` が有効ならpruneする。
    @discardableResult
    public func sync(prune: Bool = false) async -> AppStatus {
        await enqueue { await self.performSync(prune: prune || self.app.syncPolicy.prune) }
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

    private static func stateFile(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("state.json")
    }

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
                try await apply(revision: revision, manifests: manifests, prune: app.syncPolicy.prune)
            }
        } catch {
            status.error = "\(error)"
            status.sync = .unknown
            status.lastReconciledAt = now()
        }
    }

    private func performSync(prune: Bool) async {
        status.phase = .syncing
        defer { status.phase = .idle }
        do {
            let (revision, manifests) = try await fetchAndRender()
            try await apply(revision: revision, manifests: manifests, prune: prune)
        } catch {
            status.error = "\(error)"
            status.lastReconciledAt = now()
        }
    }

    private func apply(revision: GitRevision, manifests: RenderedManifests, prune: Bool) async throws {
        status.phase = .syncing
        let namespace = app.destination.namespace
        try await cluster.ensureNamespace(namespace)
        _ = try await cluster.apply(manifests, namespace: namespace)
        if prune {
            let managed = try await cluster.managedObjects(appName: app.name, namespace: namespace)
            let orphans = PrunePlanner.orphans(desired: manifests.resources, managed: managed)
            _ = try await cluster.delete(orphans, namespace: namespace)
        }
        let syncedAt = now()
        status.lastSyncedAt = syncedAt
        status.lastSyncedRevision = revision.sha
        try await compare(revision: revision, manifests: manifests)
        try SyncState(app: app, lastSyncedRevision: revision.sha, lastSyncedAt: syncedAt)
            .save(to: Self.stateFile(in: workDirectory))
    }

    private func compare(revision: GitRevision, manifests: RenderedManifests) async throws {
        let namespace = app.destination.namespace
        let diff: DiffResult
        let live: [LiveObject]
        let orphans: [LiveObject]
        if try await cluster.namespaceExists(namespace) {
            diff = try await cluster.diff(manifests, namespace: namespace)
            live = try await cluster.liveObjects(manifests, namespace: namespace)
            let managed = try await cluster.managedObjects(appName: app.name, namespace: namespace)
            orphans = PrunePlanner.orphans(desired: manifests.resources, managed: managed)
        } else {
            // namespaceが無いとサーバーサイドのdiffが失敗するので、全リソース未作成として扱う。
            diff = DiffResult(outOfSync: Set(manifests.resources), hasDiff: !manifests.resources.isEmpty)
            live = []
            orphans = []
        }

        let liveByRef = Dictionary(live.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let resources = manifests.resources.map { ref -> ResourceStatus in
            let health = liveByRef[ref].map(HealthAssessor.assess) ?? HealthResult(.missing)
            let sync: SyncStatus = diff.outOfSync.contains(ref) || liveByRef[ref] == nil ? .outOfSync : .synced
            return ResourceStatus(ref: ref, sync: sync, health: health.status, message: health.message)
        }

        let pruneTargets = orphans.map { object in
            ResourceStatus(
                ref: object.ref, sync: .outOfSync, health: HealthAssessor.assess(object).status,
                message: "requires pruning", requiresPruning: true)
        }

        status.revision = revision.sha
        status.revisionMessage = revision.message
        status.resources = resources + pruneTargets
        status.sync = diff.hasDiff || status.resources.contains { $0.sync == .outOfSync } ? .outOfSync : .synced
        // ヘルスはGitにあるリソースだけで判断する。消す予定のリソースの状態でアプリ全体を悪く見せない。
        status.health = HealthAssessor.aggregate(resources.map(\.health))
        status.error = nil
        status.lastReconciledAt = now()
    }
}
