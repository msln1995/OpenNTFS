import Foundation
import OpenNTFSCore

do {
    let snapshot = try SystemInspector().snapshot()
    let engine = RecommendationEngine()
    let report = snapshot.volumes.map { volume in
        (volume, engine.recommend(volume: volume, capabilities: snapshot.backends, conflicts: snapshot.conflicts))
    }

    if CommandLine.arguments.contains("--json") {
        struct JSONReport: Codable {
            let system: SystemSnapshot
            let recommendations: [VolumeRecommendation]
        }
        let data = try JSONEncoder.pretty.encode(JSONReport(system: snapshot, recommendations: report.map(\.1)))
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("OpenNTFS 诊断")
        print("系统：\(snapshot.osVersion) / \(snapshot.architecture)")
        print("NTFS 设备：\(snapshot.volumes.count)")
        for (volume, recommendation) in report {
            print("- \(volume.name) (\(volume.id)): \(recommendation.title)")
            print("  \(recommendation.explanation)")
        }
        for conflict in snapshot.conflicts {
            print("警告：\(conflict)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("OpenNTFS: \(error.localizedDescription)\n".utf8))
    exit(1)
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
