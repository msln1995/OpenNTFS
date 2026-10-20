import XCTest
@testable import OpenNTFSCore

final class OpenNTFSCoreTests: XCTestCase {
    func testWholeDiskIdentifierStripsOnlyPartitionSuffix() {
        XCTAssertEqual(MountService.wholeDiskIdentifier(for: "disk4s1"), "disk4")
        XCTAssertEqual(MountService.wholeDiskIdentifier(for: "disk10s12"), "disk10")
        XCTAssertNil(MountService.wholeDiskIdentifier(for: "disk4"))
        XCTAssertNil(MountService.wholeDiskIdentifier(for: "/dev/disk4s1"))
        XCTAssertNil(MountService.wholeDiskIdentifier(for: "disk4s1;reboot"))
    }

    func testParseStatusReadsRealAnyLinuxFSFormat() {
        let output = """
        /dev/disk4s1 on /Users/test/Volumes/OpenNTFS-disk4s1 (nfs,nodev,nosuid,mounted by test) VM[cpus: 4, ram: 2048 MiB]
        /dev/disk10s2 on /Volumes/OTHER (ntfs3,read-only) VM[cpus: 2, ram: 1024 MiB]

        unrelated output
        """

        let mounts = MountService.parseStatus(output)

        XCTAssertEqual(mounts.count, 2)
        XCTAssertEqual(mounts["disk4s1"], "/Users/test/Volumes/OpenNTFS-disk4s1")
        XCTAssertEqual(mounts["disk10s2"], "/Volumes/OTHER")
    }

    func testDiskScannerUsesPartitionInternalFlag() throws {
        let plist: [String: Any] = [
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
                            "DeviceIdentifier": "disk9s2",
                            "VolumeName": "Backup",
                            "MountPoint": "",
                            "Size": 2_000,
                            "OSInternal": false,
                        ],
                    ],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let volumes = try DiskScanner.parseVolumes(from: data)

        XCTAssertEqual(volumes.count, 2)
        XCTAssertTrue(volumes[0].isInternal)
        XCTAssertFalse(volumes[1].isInternal)
        XCTAssertNil(volumes[1].mountPoint)
        XCTAssertFalse(volumes[1].isWritable)
    }

    func testDiskScannerFallsBackToIdentifierForBlankVolumeName() throws {
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "Partitions": [
                        [
                            "Content": "Windows_NTFS",
                            "DeviceIdentifier": "disk9s1",
                            "VolumeName": "   ",
                        ],
                    ],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let volume = try XCTUnwrap(DiskScanner.parseVolumes(from: data).first)

        XCTAssertEqual(volume.name, "disk9s1")
        XCTAssertNil(volume.mountPoint)
        XCTAssertFalse(volume.isWritable)
    }

    func testRecommendationRequiresImplementedWriteBackend() {
        let volume = testVolume()
        let engine = RecommendationEngine()
        let onlyUnsupported = [
            BackendCapability(kind: .nativeFSKit, installed: true, ready: true, detail: "ready"),
            BackendCapability(kind: .fuseT, installed: true, ready: true, detail: "ready"),
        ]

        let recommendation = engine.recommend(
            volume: volume,
            capabilities: onlyUnsupported,
            conflicts: []
        )

        XCTAssertEqual(recommendation.backend, .unavailable)
        XCTAssertEqual(recommendation.safety, .readOnly)
        XCTAssertTrue(recommendation.explanation.contains("原生模式"))
    }

    func testRecommendationSelectsMicroVMWhenReady() {
        let capabilities = [
            BackendCapability(kind: .nativeFSKit, installed: true, ready: true, detail: "ready"),
            BackendCapability(kind: .microVM, installed: true, ready: true, detail: "ready"),
        ]

        let recommendation = RecommendationEngine().recommend(
            volume: testVolume(),
            capabilities: capabilities,
            conflicts: []
        )

        XCTAssertEqual(recommendation.backend, .microVM)
        XCTAssertEqual(recommendation.safety, .safe)
    }

    func testWritePlanDoesNotForceDirtyVolumes() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/opt/homebrew/bin/anylinuxfs") ||
                FileManager.default.fileExists(atPath: "/usr/local/bin/anylinuxfs"),
            "anylinuxfs is not installed"
        )

        let plan = try MountService().planEnableWrite(volume: testVolume(), backend: .microVM)

        XCTAssertFalse(plan.arguments.contains("force"))
        XCTAssertFalse(plan.arguments.contains("locallocks"))
        XCTAssertTrue(plan.arguments.contains("ntfs3"))
        XCTAssertTrue(plan.arguments.contains("rw,async,no_subtree_check,no_root_squash,insecure"))

        let optionIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-n"))
        XCTAssertEqual(plan.arguments[optionIndex + 1], "wsize=1048576,rsize=1048576,tcp")
        XCTAssertTrue(plan.arguments.contains("/dev/disk9s1"))
        XCTAssertEqual(
            plan.targetMountPoint,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Volumes/OpenNTFS-disk9s1").path
        )
    }

    func testUnimplementedBackendIsRejected() {
        XCTAssertThrowsError(
            try MountService().planEnableWrite(volume: testVolume(), backend: .nativeFSKit)
        ) { error in
            XCTAssertEqual(error as? MountServiceError, .unsupportedBackend)
        }
    }

    func testInternalDiskIsRejectedBeforeRunningCommands() {
        let volume = NTFSVolume(
            id: "disk1s1",
            name: "Windows",
            mountPoint: nil,
            size: 1_000,
            isWritable: false,
            isInternal: true
        )

        XCTAssertThrowsError(try MountService().safeEject(volume: volume)) { error in
            XCTAssertEqual(error as? MountServiceError, .internalDisk)
        }
    }

    private func testVolume() -> NTFSVolume {
        NTFSVolume(
            id: "disk9s1",
            name: "Test",
            mountPoint: "/Volumes/Test",
            size: 1_000,
            isWritable: false,
            isInternal: false
        )
    }
}
