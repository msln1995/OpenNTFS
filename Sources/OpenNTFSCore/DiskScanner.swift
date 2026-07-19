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
        guard let root = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw DiskScannerError.invalidPropertyList
        }

        return disks.flatMap { disk -> [NTFSVolume] in
            let internalDisk = disk["OSInternal"] as? Bool ?? false
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            return partitions.compactMap { partition in
                guard partition["Content"] as? String == "Windows_NTFS",
                      let identifier = partition["DeviceIdentifier"] as? String else {
                    return nil
                }
                let name = partition["VolumeName"] as? String ?? identifier
                let mountPoint = partition["MountPoint"] as? String
                let size = (partition["Size"] as? NSNumber)?.int64Value ?? 0
                let writable = mountPoint.map(isMountWritable) ?? false
                return NTFSVolume(
                    id: identifier,
                    name: name,
                    mountPoint: mountPoint,
                    size: size,
                    isWritable: writable,
                    isInternal: internalDisk
                )
            }
        }
    }

    private func isMountWritable(_ mountPoint: String) -> Bool {
        FileManager.default.isWritableFile(atPath: mountPoint)
    }
}
