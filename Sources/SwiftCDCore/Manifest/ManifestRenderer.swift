import Foundation
import Yams

public struct RenderedManifests: Sendable, Equatable {
    /// kubectlに渡す `kind: List` 形式のJSONファイル
    public var file: URL
    public var resources: [ResourceRef]
}

/// ArgoCDのrepo-serverに相当する。プレーンなYAMLを読み、管理ラベルを付けて1ファイルにまとめる。
public enum ManifestRenderer {
    public static let appLabel = "swiftcd.io/app"

    public static func render(sourceDirectory: URL, appName: String, output: URL) throws -> RenderedManifests {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SwiftCDError.pathNotFound(sourceDirectory.path)
        }

        let files = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { ["yaml", "yml", "json"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var objects: [[String: Any]] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for document in try Yams.load_all(yaml: text) {
                guard let object = normalize(document) as? [String: Any] else {
                    continue
                }
                objects.append(contentsOf: expandList(object))
            }
        }

        var resources: [ResourceRef] = []
        for index in objects.indices {
            guard let apiVersion = objects[index]["apiVersion"] as? String,
                  let kind = objects[index]["kind"] as? String,
                  var metadata = objects[index]["metadata"] as? [String: Any],
                  let name = metadata["name"] as? String else {
                throw SwiftCDError.invalidManifest("apiVersion/kind/metadata.name is required")
            }
            var labels = metadata["labels"] as? [String: Any] ?? [:]
            labels[appLabel] = appName
            metadata["labels"] = labels
            objects[index]["metadata"] = metadata
            resources.append(ResourceRef(apiVersion: apiVersion, kind: kind, name: name))
        }

        // YAMLのまま書き出すと "8080" のような文字列が数値に化けうるので、JSONで書き出す。
        let list: [String: Any] = ["apiVersion": "v1", "kind": "List", "items": objects]
        let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output)
        return RenderedManifests(file: output, resources: resources)
    }

    private static func expandList(_ object: [String: Any]) -> [[String: Any]] {
        if let kind = object["kind"] as? String, kind.hasSuffix("List"), let items = object["items"] as? [Any] {
            return items.compactMap { $0 as? [String: Any] }
        }
        return [object]
    }

    /// Yamsの `[AnyHashable: Any]` などを、JSONSerializationが扱える型へ揃える。
    static func normalize(_ value: Any?) -> Any {
        switch value {
        case nil:
            return NSNull()
        case let dict as [AnyHashable: Any]:
            var result: [String: Any] = [:]
            for (key, inner) in dict {
                result["\(key.base)"] = normalize(inner)
            }
            return result
        case let array as [Any]:
            return array.map { normalize($0) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let data as Data:
            return data.base64EncodedString()
        case let value?:
            return value
        }
    }
}
