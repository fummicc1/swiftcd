import Foundation
import Hummingbird
import SwiftCDCore

enum Routes {
    static func register(on router: Router<BasicRequestContext>, store: AppStore) {
        let indexHTML = loadIndexHTML()

        router.get("/") { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: indexHTML)))
        }

        let api = router.group("api/apps")
        api.get { _, _ in
            try json(await store.list())
        }
        api.get(":name") { _, context in
            let name = try context.parameters.require("name")
            return try await handle { try await store.get(name) }
        }
        api.post(":name/sync") { _, context in
            let name = try context.parameters.require("name")
            return try await handle { try await store.sync(name) }
        }
        api.post(":name/refresh") { _, context in
            let name = try context.parameters.require("name")
            return try await handle { try await store.refresh(name) }
        }
    }

    private static func handle(_ body: () async throws -> AppStatus) async throws -> Response {
        do {
            return try json(try await body())
        } catch SwiftCDError.appNotFound(let name) {
            throw HTTPError(.notFound, message: "application '\(name)' not found")
        }
    }

    private static func json(_ value: some Encodable) throws -> Response {
        let data = try APICoding.encoder.encode(value)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func loadIndexHTML() -> String {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Public"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            return "<h1>index.html not found</h1>"
        }
        return html
    }
}
