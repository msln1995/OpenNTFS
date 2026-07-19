import Foundation

public struct NTFSVolume: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mountPoint: String?
    public let size: Int64
    public let isWritable: Bool
    public let isInternal: Bool

    public init(
        id: String,
        name: String,
        mountPoint: String?,
        size: Int64,
        isWritable: Bool,
        isInternal: Bool
    ) {
        self.id = id
        self.name = name
        self.mountPoint = mountPoint
        self.size = size
        self.isWritable = isWritable
        self.isInternal = isInternal
    }
}

public enum BackendKind: String, Codable, CaseIterable, Sendable {
    case nativeFSKit = "fskit"
    case fuseT = "fuse-t"
    case macFUSE = "macfuse"
    case microVM = "microvm"
    case unavailable

    public var displayName: String {
        switch self {
        case .nativeFSKit: "原生模式"
        case .fuseT: "免恢复模式"
        case .macFUSE: "兼容模式"
        case .microVM: "隔离兼容模式"
        case .unavailable: "只读模式"
        }
    }

    public var requiresRecoveryMode: Bool {
        self == .macFUSE
    }
}

public struct BackendCapability: Codable, Equatable, Sendable {
    public let kind: BackendKind
    public let installed: Bool
    public let ready: Bool
    public let detail: String

    public init(kind: BackendKind, installed: Bool, ready: Bool, detail: String) {
        self.kind = kind
        self.installed = installed
        self.ready = ready
        self.detail = detail
    }
}

public enum SafetyLevel: String, Codable, Sendable {
    case safe
    case readOnly
    case blocked
}

public struct VolumeRecommendation: Codable, Equatable, Sendable {
    public let volumeID: String
    public let backend: BackendKind
    public let safety: SafetyLevel
    public let title: String
    public let explanation: String

    public init(
        volumeID: String,
        backend: BackendKind,
        safety: SafetyLevel,
        title: String,
        explanation: String
    ) {
        self.volumeID = volumeID
        self.backend = backend
        self.safety = safety
        self.title = title
        self.explanation = explanation
    }
}

public struct SystemSnapshot: Codable, Sendable {
    public let osVersion: String
    public let architecture: String
    public let volumes: [NTFSVolume]
    public let backends: [BackendCapability]
    public let conflicts: [String]
    public let notices: [String]

    public init(
        osVersion: String,
        architecture: String,
        volumes: [NTFSVolume],
        backends: [BackendCapability],
        conflicts: [String],
        notices: [String]
    ) {
        self.osVersion = osVersion
        self.architecture = architecture
        self.volumes = volumes
        self.backends = backends
        self.conflicts = conflicts
        self.notices = notices
    }
}

public struct DriverAssessment: Equatable, Sendable {
    public let conflicts: [String]
    public let notices: [String]

    public init(conflicts: [String], notices: [String]) {
        self.conflicts = conflicts
        self.notices = notices
    }
}
