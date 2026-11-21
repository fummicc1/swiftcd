import Foundation
import Testing
@testable import SwiftCDCore

@Suite struct ManifestRendererTests {
    @Test func 複数ドキュメントを読み込み管理ラベルを付ける() throws {
        let source = try temporaryDirectory()
        try """
        apiVersion: v1
        kind: Service
        metadata:
          name: web
          labels: { tier: frontend }
        spec:
          ports: [{ port: 80 }]
        ---
        # 空ドキュメントは無視される
        ---
        apiVersion: v1
        kind: ConfigMap
        metadata: { name: config }
        data:
          PORT: "8080"
          ENABLED: "true"
        """.write(to: source.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)
        try deploymentYAML().write(to: source.appendingPathComponent("b.yml"), atomically: true, encoding: .utf8)
        try "ignored".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let output = try temporaryDirectory().appendingPathComponent("rendered.json")
        let rendered = try ManifestRenderer.render(sourceDirectory: source, appName: "demo", output: output)

        #expect(rendered.resources == [
            ResourceRef(group: "", kind: "Service", name: "web"),
            ResourceRef(group: "", kind: "ConfigMap", name: "config"),
            ResourceRef(group: "apps", kind: "Deployment", name: "web"),
        ])

        let list = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        let items = try #require(list["items"] as? [[String: Any]])
        let serviceLabels = (items[0]["metadata"] as? [String: Any])?["labels"] as? [String: String]
        #expect(serviceLabels == ["tier": "frontend", "swiftcd.io/app": "demo"])

        // 引用符付きの値は数値や真偽値に化けず、文字列のまま残る。
        let data = items[1]["data"] as? [String: Any]
        #expect(data?["PORT"] as? String == "8080")
        #expect(data?["ENABLED"] as? String == "true")
    }

    @Test func Listは中身のitemsに展開する() throws {
        let source = try temporaryDirectory()
        try """
        apiVersion: v1
        kind: List
        items:
          - { apiVersion: v1, kind: ConfigMap, metadata: { name: a } }
          - { apiVersion: v1, kind: ConfigMap, metadata: { name: b } }
        """.write(to: source.appendingPathComponent("list.yaml"), atomically: true, encoding: .utf8)

        let rendered = try ManifestRenderer.render(
            sourceDirectory: source, appName: "demo", output: try temporaryDirectory().appendingPathComponent("r.json"))

        #expect(rendered.resources.map(\.name) == ["a", "b"])
    }

    @Test func nameがないマニフェストはエラー() throws {
        let source = try temporaryDirectory()
        try "apiVersion: v1\nkind: ConfigMap\nmetadata: {}\n"
            .write(to: source.appendingPathComponent("bad.yaml"), atomically: true, encoding: .utf8)

        #expect(throws: SwiftCDError.self) {
            try ManifestRenderer.render(
                sourceDirectory: source, appName: "demo", output: try temporaryDirectory().appendingPathComponent("r.json"))
        }
    }
}
