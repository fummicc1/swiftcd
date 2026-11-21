import Foundation

public struct HealthResult: Sendable, Equatable {
    public var status: HealthStatus
    public var message: String?

    public init(_ status: HealthStatus, _ message: String? = nil) {
        self.status = status
        self.message = message
    }
}

public enum HealthAssessor {
    public static func assess(_ object: LiveObject) -> HealthResult {
        guard let json = try? JSONSerialization.jsonObject(with: object.json) as? [String: Any] else {
            return HealthResult(.unknown, "failed to parse live object")
        }
        switch object.ref.kind {
        case "Deployment", "StatefulSet", "ReplicaSet":
            return assessWorkload(json)
        case "Pod":
            return assessPod(json)
        default:
            // Service, ConfigMapなどは存在していればHealthyとみなす。
            return HealthResult(.healthy)
        }
    }

    public static func aggregate(_ statuses: [HealthStatus]) -> HealthStatus {
        statuses.max() ?? .healthy
    }

    static func assessWorkload(_ json: [String: Any]) -> HealthResult {
        let spec = json["spec"] as? [String: Any] ?? [:]
        let status = json["status"] as? [String: Any] ?? [:]
        let metadata = json["metadata"] as? [String: Any] ?? [:]

        let desired = intValue(spec["replicas"]) ?? 1
        let generation = intValue(metadata["generation"]) ?? 0
        let observed = intValue(status["observedGeneration"]) ?? 0
        let updated = intValue(status["updatedReplicas"]) ?? 0
        let ready = intValue(status["readyReplicas"]) ?? 0
        let available = intValue(status["availableReplicas"]) ?? ready

        let conditions = status["conditions"] as? [[String: Any]] ?? []
        if let progressing = conditions.first(where: { $0["type"] as? String == "Progressing" }),
           progressing["reason"] as? String == "ProgressDeadlineExceeded" {
            return HealthResult(.degraded, progressing["message"] as? String)
        }
        if observed < generation {
            return HealthResult(.progressing, "waiting for rollout to be observed")
        }
        if updated < desired {
            return HealthResult(.progressing, "\(updated)/\(desired) replicas updated")
        }
        if available < desired {
            return HealthResult(.progressing, "\(available)/\(desired) replicas available")
        }
        return HealthResult(.healthy, "\(available)/\(desired) replicas available")
    }

    static func assessPod(_ json: [String: Any]) -> HealthResult {
        let status = json["status"] as? [String: Any] ?? [:]
        switch status["phase"] as? String {
        case "Running":
            let conditions = status["conditions"] as? [[String: Any]] ?? []
            let ready = conditions.contains { $0["type"] as? String == "Ready" && $0["status"] as? String == "True" }
            return ready ? HealthResult(.healthy) : HealthResult(.progressing, "pod is not ready")
        case "Succeeded":
            return HealthResult(.healthy)
        case "Failed":
            return HealthResult(.degraded, status["message"] as? String)
        default:
            return HealthResult(.progressing, status["phase"] as? String)
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
