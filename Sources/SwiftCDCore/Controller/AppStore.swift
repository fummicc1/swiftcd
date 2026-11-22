import Foundation

/// 全アプリのControllerをまとめて管理する。
public actor AppStore {
    private var controllers: [String: AppController] = [:]
    private var order: [String] = []

    public init(
        apps: [Application],
        git: GitClient,
        cluster: ClusterClient,
        workDirectory: URL,
        interval: Duration
    ) {
        for app in apps {
            controllers[app.name] = AppController(
                app: app,
                git: git,
                cluster: cluster,
                workDirectory: workDirectory.appendingPathComponent("apps").appendingPathComponent(app.name),
                interval: interval)
            order.append(app.name)
        }
    }

    public func startAll() async {
        for name in order {
            await controllers[name]?.start()
        }
    }

    public func stopAll() async {
        for name in order {
            await controllers[name]?.stop()
        }
    }

    public func list() async -> [AppStatus] {
        var result: [AppStatus] = []
        for name in order {
            if let controller = controllers[name] {
                result.append(await controller.status)
            }
        }
        return result
    }

    public func get(_ name: String) async throws -> AppStatus {
        try await controller(name).status
    }

    public func sync(_ name: String, prune: Bool = false) async throws -> AppStatus {
        try await controller(name).sync(prune: prune)
    }

    public func refresh(_ name: String) async throws -> AppStatus {
        try await controller(name).refresh()
    }

    private func controller(_ name: String) throws -> AppController {
        guard let controller = controllers[name] else {
            throw SwiftCDError.appNotFound(name)
        }
        return controller
    }
}
