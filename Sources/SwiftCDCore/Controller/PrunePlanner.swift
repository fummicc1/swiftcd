import Foundation

/// 管理ラベル付きのライブリソースのうち、Gitのマニフェストに無いもの（prune対象）を選ぶ。
public enum PrunePlanner {
    /// Serviceのラベルがコピーされるだけで、SwiftCDがapplyしたものではない種類。
    static let excludedKinds: Set<String> = ["Endpoints", "EndpointSlice", "Event"]

    public static func orphans(desired: [ResourceRef], managed: [LiveObject]) -> [LiveObject] {
        let desiredSet = Set(desired)
        return managed.filter { object in
            !desiredSet.contains(object.ref)
                && !excludedKinds.contains(object.ref.kind)
                && !hasOwner(object)
        }
    }

    /// ownerReferencesを持つもの（Deploymentが作ったReplicaSetなど）は親と一緒に消えるので、直接は消さない。
    private static func hasOwner(_ object: LiveObject) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: object.json) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any],
              let owners = metadata["ownerReferences"] as? [Any] else {
            return false
        }
        return !owners.isEmpty
    }
}
