import Foundation
import Testing
@testable import SwiftCDCore

@Suite struct HealthAssessorTests {
    private func live(_ kind: String, _ object: [String: Any]) throws -> LiveObject {
        LiveObject(
            ref: ResourceRef(group: "apps", kind: kind, name: "web"),
            json: try JSONSerialization.data(withJSONObject: object))
    }

    private func deployment(generation: Int = 1, observed: Int = 1, updated: Int, available: Int, conditions: [[String: Any]] = []) -> [String: Any] {
        [
            "metadata": ["generation": generation],
            "spec": ["replicas": 2],
            "status": [
                "observedGeneration": observed, "updatedReplicas": updated,
                "readyReplicas": available, "availableReplicas": available, "conditions": conditions,
            ],
        ]
    }

    @Test func 全レプリカが利用可能ならHealthy() throws {
        let result = HealthAssessor.assess(try live("Deployment", deployment(updated: 2, available: 2)))
        #expect(result.status == .healthy)
    }

    @Test func ロールアウト中はProgressing() throws {
        #expect(HealthAssessor.assess(try live("Deployment", deployment(updated: 1, available: 2))).status == .progressing)
        #expect(HealthAssessor.assess(try live("Deployment", deployment(updated: 2, available: 1))).status == .progressing)
        #expect(HealthAssessor.assess(try live("Deployment", deployment(generation: 2, observed: 1, updated: 2, available: 2))).status == .progressing)
    }

    @Test func 期限切れのロールアウトはDegraded() throws {
        let condition: [String: Any] = ["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded", "message": "timeout"]
        let result = HealthAssessor.assess(try live("Deployment", deployment(updated: 1, available: 0, conditions: [condition])))
        #expect(result == HealthResult(.degraded, "timeout"))
    }

    @Test func Podのphaseで判定する() throws {
        let ready: [String: Any] = ["status": ["phase": "Running", "conditions": [["type": "Ready", "status": "True"]]]]
        #expect(HealthAssessor.assess(try live("Pod", ready)).status == .healthy)
        #expect(HealthAssessor.assess(try live("Pod", ["status": ["phase": "Pending"]])).status == .progressing)
        #expect(HealthAssessor.assess(try live("Pod", ["status": ["phase": "Failed"]])).status == .degraded)
    }

    @Test func その他のリソースは存在すればHealthy() throws {
        #expect(HealthAssessor.assess(try live("Service", [:])).status == .healthy)
    }

    @Test func 集約は最も悪い状態になる() {
        #expect(HealthAssessor.aggregate([.healthy, .progressing, .missing]) == .missing)
        #expect(HealthAssessor.aggregate([.healthy, .degraded, .missing]) == .degraded)
        #expect(HealthAssessor.aggregate([]) == .healthy)
    }
}
