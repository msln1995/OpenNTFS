import Foundation
import OpenNTFSCore

var failures: [String] = []
var checkCount = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    if condition() {
        print("PASS: \(message)")
    } else {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

let engine = RecommendationEngine()
let externalVolume = NTFSVolume(
    id: "disk9s1",
    name: "Test",
    mountPoint: "/Volumes/Test",
    size: 1_000,
    isWritable: false,
    isInternal: false
)
let readyBackends = [
    BackendCapability(kind: .nativeFSKit, installed: true, ready: true, detail: "ready"),
    BackendCapability(kind: .macFUSE, installed: true, ready: true, detail: "ready"),
]

let unimplemented = engine.recommend(volume: externalVolume, capabilities: readyBackends, conflicts: [])
check(unimplemented.backend == .unavailable, "detected but unimplemented backends stay read-only")
check(unimplemented.safety == .readOnly, "an unimplemented backend is not advertised as writable")

let microVMReady = engine.recommend(
    volume: externalVolume,
    capabilities: readyBackends + [
        BackendCapability(kind: .microVM, installed: true, ready: true, detail: "ready"),
    ],
    conflicts: []
)
check(microVMReady.backend == .microVM, "microVM is the only recommended write backend")
check(microVMReady.safety == .safe, "a verified microVM backend is considered safe")

let conflict = engine.recommend(
    volume: externalVolume,
    capabilities: readyBackends,
    conflicts: ["another driver"]
)
check(conflict.backend == .unavailable, "driver conflicts prevent automatic switching")
check(conflict.safety == .readOnly, "driver conflicts fall back to read-only")

let internalVolume = NTFSVolume(
    id: "disk1s1",
    name: "Windows",
    mountPoint: nil,
    size: 1_000,
    isWritable: false,
    isInternal: true
)
let internalResult = engine.recommend(volume: internalVolume, capabilities: readyBackends, conflicts: [])
check(internalResult.safety == .blocked, "internal disks are never made writable")

let unavailable = engine.recommend(volume: externalVolume, capabilities: [], conflicts: [])
check(unavailable.safety == .readOnly, "missing backends fall back to read-only")

var bootSector = Data(repeating: 0, count: 512)
bootSector.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
bootSector[11] = 0x00
bootSector[12] = 0x02
bootSector[13] = 8
bootSector[40] = 0x00
bootSector[41] = 0x10
bootSector[48] = 0x04
let parsedBootSector = NTFSBootSector(data: bootSector)
check(parsedBootSector?.bytesPerSector == 512, "NTFS boot-sector parser reads sector size")
check(parsedBootSector?.bytesPerCluster == 4096, "NTFS boot-sector parser reads cluster size")
bootSector[3] = 0
check(NTFSBootSector(data: bootSector) == nil, "non-NTFS boot sectors are rejected")

do {
    let plan = try MountService().planEnableWrite(volume: externalVolume, backend: .microVM)
check(!plan.arguments.contains("--remount"), "write plan avoids probing a device still owned by Apple FSKit")
let expectedMountPoint = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Volumes/OpenNTFS-disk9s1").path
check(plan.arguments.contains(expectedMountPoint), "write plan uses an ASCII user-owned NFS mount point")
check(plan.targetMountPoint == expectedMountPoint, "write plan prepares the explicit NFS mount point")
    check(!plan.arguments.contains("--ignore-permissions"), "write plan avoids the macOS 27 permission-bypass hang")
check(plan.arguments.contains("/dev/disk9s1"), "write plan uses the validated device node")
    check(plan.readableDevicePath == "/dev/disk9s1", "write plan keeps the device path for safe rollback")
    check(plan.releaseMountedDeviceFirst, "write plan releases the Apple read-only mount before probing")
    check(plan.arguments.contains("ntfs3"), "write plan prioritizes Linux in-kernel ntfs3 driver")
    check(!plan.arguments.contains("force"), "write plan never forces hibernated or dirty NTFS volumes")
    check(plan.arguments.contains("--nfs-export-opts"), "write plan configures asynchronous NFS export")
    let nfsOptionIndex = plan.arguments.firstIndex(of: "-n")
    let nfsOptions = nfsOptionIndex.map { plan.arguments[$0 + 1] } ?? ""
    check(nfsOptions == "wsize=1048576,rsize=1048576,tcp", "write plan omits ineffective client async and locking flags")
} catch {
    check(false, "microVM write plan is available")
}

let wholeDiskCases = ["disk4s1": "disk4", "disk10s12": "disk10"]
for (volumeID, expectedDisk) in wholeDiskCases {
    check(
        MountService.wholeDiskIdentifier(for: volumeID) == expectedDisk,
        "whole-disk identifier for \(volumeID) is \(expectedDisk)"
    )
}
check(MountService.wholeDiskIdentifier(for: "disk4") == nil, "whole-disk parser rejects a disk without partition")
check(MountService.wholeDiskIdentifier(for: "/dev/disk4s1") == nil, "whole-disk parser rejects a path")

let statusOutput = """
/dev/disk4s1 on /Users/test/Volumes/OpenNTFS-disk4s1 (nfs,nodev,nosuid,mounted by test) VM[cpus: 4, ram: 2048 MiB]
unrelated output
"""
let parsedMounts = MountService.parseStatus(statusOutput)
check(parsedMounts.count == 1, "anylinuxfs status parser ignores unrelated lines")
check(
    parsedMounts["disk4s1"] == "/Users/test/Volumes/OpenNTFS-disk4s1",
    "anylinuxfs status parser reads the active NFS mount point"
)

let diskListPlist: [String: Any] = [
    "AllDisksAndPartitions": [
        [
            "OSInternal": false,
            "Partitions": [
                [
                    "Content": "Windows_NTFS",
                    "DeviceIdentifier": "disk1s1",
                    "VolumeName": "Windows",
                    "MountPoint": "/Volumes/Windows",
                    "Size": 1_000,
                    "OSInternal": true,
                ],
                [
                    "Content": "Windows_NTFS",
                    "DeviceIdentifier": "disk9s1",
                    "VolumeName": "   ",
                    "MountPoint": "",
                    "Size": 2_000,
                    "OSInternal": false,
                ],
            ],
        ],
    ],
]
do {
    let data = try PropertyListSerialization.data(
        fromPropertyList: diskListPlist,
        format: .xml,
        options: 0
    )
    let volumes = try DiskScanner.parseVolumes(from: data)
    check(volumes.count == 2, "disk scanner parses NTFS partitions")
    check(volumes.first?.isInternal == true, "disk scanner reads OSInternal at the partition level")
    check(volumes.last?.isInternal == false, "external partitions stay eligible for writes")
    check(volumes.last?.name == "disk9s1", "blank volume labels fall back to the device identifier")
    check(volumes.last?.mountPoint == nil, "empty mount point values are ignored")
} catch {
    check(false, "disk scanner parses the diskutil property list")
}
let invalidVolume = NTFSVolume(
    id: "disk9s1;touch /tmp/bad",
    name: "Invalid",
    mountPoint: nil,
    size: 1_000,
    isWritable: false,
    isInternal: false
)
do {
    _ = try MountService().planEnableWrite(volume: invalidVolume, backend: .microVM)
    check(false, "invalid device identifiers are rejected")
} catch MountServiceError.invalidDeviceIdentifier {
    check(true, "invalid device identifiers are rejected")
} catch {
    check(false, "invalid device identifiers are rejected")
}

if failures.isEmpty {
    print("OpenNTFS self-test passed (\(checkCount) checks)")
} else {
    FileHandle.standardError.write(Data("OpenNTFS self-test failed: \(failures.joined(separator: ", "))\n".utf8))
    exit(1)
}
