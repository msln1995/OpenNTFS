import Foundation

public struct SystemInspector: Sendable {
    private let scanner: DiskScanner
    private let detector: BackendDetector

    public init(
        scanner: DiskScanner = DiskScanner(),
        detector: BackendDetector = BackendDetector()
    ) {
        self.scanner = scanner
        self.detector = detector
    }

    public func snapshot() throws -> SystemSnapshot {
        let drivers = detector.assessDrivers()
        return SystemSnapshot(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            volumes: try scanner.scanExternalNTFSVolumes(),
            backends: detector.detect(),
            conflicts: drivers.conflicts,
            notices: drivers.notices
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
