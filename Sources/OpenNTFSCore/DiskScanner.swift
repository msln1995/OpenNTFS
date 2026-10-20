import Foundation

public enum DiskScannerError: Error, LocalizedError {
    case commandFailed(String)
    case invalidPropertyList

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .invalidPropertyList: "无法解析 diskutil 返回的磁盘信息"
        }
    }
}

public struct DiskScanner: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func scanExternalNTFSVolumes() throws -> [NTFSVolume] {
        let result = try runner.run("/usr/sbin/diskutil", arguments: ["list", "-plist", "external", "physical"])
        guard result.status == 0 else {
            throw DiskScannerError.commandFailed(result.stderrString)
        }
        return try Self.parseVolumes(from: result.stdout)
    }

    public static func parseVolumes(from data: Data) throws -> [NTFSVolume] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw DiskScannerError.invalidPropertyList
        }

        return disks.flatMap { disk -> [NTFSVolume] in
            let diskIsInternal = disk["OSInternal"] as? Bool ?? false
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            return partitions.compactMap { partition in
                guard partition["Content"] as? String == "Windows_NTFS",
                      let identifier = parseString(partition["DeviceIdentifier"]) else {
                    return nil
                }
                let name = parseString(partition["VolumeName"]) ?? identifier
                let mountPoint = parseString(partition["MountPoint"])
                let size = (partition["Size"] as? NSNumber)?.int64Value ?? 0
                let writable = mountPoint.map(isMountWritable) ?? false
                return NTFSVolume(
                    id: identifier,
                    name: name,
                    mountPoint: mountPoint,
                    size: size,
                    isWritable: writable,
                    isInternal: partition["OSInternal"] as? Bool ?? diskIsInternal
                )
            }
        }
    }

    private static func parseString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isMountWritable(_ mountPoint: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: mountPoint)
            .resourceValues(forKeys: [.volumeIsReadOnlyKey]),
              let isReadOnly = values.volumeIsReadOnly else {
            return false
        }
        return !isReadOnly
    }
}
