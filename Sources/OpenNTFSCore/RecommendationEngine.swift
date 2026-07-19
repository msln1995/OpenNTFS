import Foundation

public struct RecommendationEngine: Sendable {
    public init() {}

    public func recommend(
        volume: NTFSVolume,
        capabilities: [BackendCapability],
        conflicts: [String]
    ) -> VolumeRecommendation {
        if volume.isInternal {
            return VolumeRecommendation(
                volumeID: volume.id,
                backend: .unavailable,
                safety: .blocked,
                title: "为保护系统磁盘，已禁止写入",
                explanation: "OpenNTFS 第一版只允许处理外置设备。"
            )
        }

        if volume.isWritable {
            return VolumeRecommendation(
                volumeID: volume.id,
                backend: .unavailable,
                safety: .safe,
                title: "当前已经可以写入",
                explanation: "无需切换驱动；可以直接使用并安全推出设备。"
            )
        }

        if !conflicts.isEmpty {
            return VolumeRecommendation(
                volumeID: volume.id,
                backend: .unavailable,
                safety: .readOnly,
                title: "发现其他 NTFS 驱动，暂不自动切换",
                explanation: "多个驱动同时接管同一磁盘可能造成冲突。请先在诊断页确认现有组件。"
            )
        }

        let priority: [BackendKind] = [.nativeFSKit, .fuseT, .microVM, .macFUSE]
        if let backend = priority.compactMap({ kind in
            capabilities.first(where: { $0.kind == kind && $0.ready })
        }).first {
            return VolumeRecommendation(
                volumeID: volume.id,
                backend: backend.kind,
                safety: .safe,
                title: "可以使用\(backend.kind.displayName)",
                explanation: backend.kind.requiresRecoveryMode
                    ? "此模式可能要求修改系统扩展设置，只在你主动选择兼容模式时使用。"
                    : "此模式不要求进入恢复模式，也不会降低系统安全设置。"
            )
        }

        return VolumeRecommendation(
            volumeID: volume.id,
            backend: .unavailable,
            safety: .readOnly,
            title: "目前保持只读最安全",
            explanation: "尚未安装无需恢复模式的写入后端。应用不会静默修改系统设置。"
        )
    }
}
