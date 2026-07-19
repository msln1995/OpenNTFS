import Foundation
import OpenNTFSCore

var failures: [String] = []

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
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

let preferred = engine.recommend(volume: externalVolume, capabilities: readyBackends, conflicts: [])
check(preferred.backend == .nativeFSKit, "FSKit wins over recovery-mode backends")
check(preferred.safety == .safe, "a verified FSKit backend is considered safe")
check(!preferred.backend.requiresRecoveryMode, "the default backend never requires Recovery Mode")

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
    check(plan.readableDevicePath == "/dev/disk9s1", "write plan checks Full Disk Access before mounting")
    check(plan.releaseMountedDeviceFirst, "write plan releases the Apple read-only mount before probing")
    check(plan.shellCommand.contains("diskutil mount"), "write plan restores the read-only mount after failure")
} catch {
    check(false, "microVM write plan is available")
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
    print("OpenNTFS self-test passed (17 checks)")
} else {
    FileHandle.standardError.write(Data("OpenNTFS self-test failed: \(failures.joined(separator: ", "))\n".utf8))
    exit(1)
}
