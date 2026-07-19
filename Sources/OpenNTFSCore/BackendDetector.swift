import Foundation

public struct BackendDetector: Sendable {
    private let environment: [String: String]
    private let runner: any CommandRunning

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.environment = environment
        self.runner = runner
    }

    public func detect() -> [BackendCapability] {
        [detectFSKit(), detectFuseT(), detectMacFUSE(), detectMicroVM()]
    }

    public func assessDrivers() -> DriverAssessment {
        var conflicts: [String] = []
        var notices: [String] = []
        let knownDrivers = [
            "/Library/Extensions/ntfstool.kext": ("com.ntfstool.filesystems.ntfstool", "ntfstool 内核扩展"),
            "/Library/Filesystems/ntfstool.fs": ("com.ntfstool", "ntfstool 文件系统组件"),
            "/Library/Filesystems/tuxera_ntfs.fs": ("tuxera", "Tuxera NTFS"),
            "/Library/Filesystems/ufsd_NTFS.fs": ("ufsd", "Paragon NTFS"),
        ]
        let activeText = loadedDriverText().lowercased()
        for (path, driver) in knownDrivers where FileManager.default.fileExists(atPath: path) {
            if activeText.contains(driver.0.lowercased()) {
                conflicts.append("正在运行：\(driver.1)")
            } else {
                notices.append("已安装但未运行：\(driver.1)")
            }
        }
        return DriverAssessment(conflicts: conflicts.sorted(), notices: notices.sorted())
    }

    private func loadedDriverText() -> String {
        let commands = [
            ("/usr/bin/kmutil", ["showloaded"]),
            ("/usr/bin/systemextensionsctl", ["list"]),
        ]
        return commands.compactMap { executable, arguments in
            guard let result = try? runner.run(executable, arguments: arguments), result.status == 0 else {
                return nil
            }
            return result.stdoutString
        }.joined(separator: "\n")
    }

    private func detectFSKit() -> BackendCapability {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let supported = major >= 15
        let extensionPath = environment["OPENNTFS_FSKIT_EXTENSION"] ?? ""
        let installed = !extensionPath.isEmpty && FileManager.default.fileExists(atPath: extensionPath)
        return BackendCapability(
            kind: .nativeFSKit,
            installed: installed,
            ready: supported && installed,
            detail: supported
                ? (installed ? "FSKit 扩展已安装" : "系统支持 FSKit，等待已签名扩展")
                : "当前系统不支持 FSKit 文件系统扩展"
        )
    }

    private func detectFuseT() -> BackendCapability {
        let paths = ["/usr/local/bin/mount_fuse-t", "/opt/homebrew/bin/mount_fuse-t"]
        let installed = paths.contains { FileManager.default.fileExists(atPath: $0) }
        return BackendCapability(
            kind: .fuseT,
            installed: installed,
            ready: installed,
            detail: installed ? "FUSE-T 已安装，无需恢复模式" : "FUSE-T 未安装"
        )
    }

    private func detectMacFUSE() -> BackendCapability {
        let installed = FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
        let ntfs3gPaths = [
            "/usr/local/sbin/ntfs-3g",
            "/usr/local/bin/ntfs-3g",
            "/opt/homebrew/sbin/ntfs-3g",
            "/opt/homebrew/bin/ntfs-3g",
        ]
        let hasNTFS3G = ntfs3gPaths.contains { FileManager.default.fileExists(atPath: $0) }
        let loaded = loadedDriverText().lowercased().contains("io.macfuse")
        return BackendCapability(
            kind: .macFUSE,
            installed: installed,
            ready: installed && hasNTFS3G && loaded,
            detail: installed
                ? (hasNTFS3G
                    ? (loaded ? "macFUSE 与 NTFS-3G 已就绪" : "组件已安装，但 macFUSE 尚未加载")
                    : "已安装 macFUSE，但缺少 NTFS-3G")
                : "macFUSE 未安装"
        )
    }

    private func detectMicroVM() -> BackendCapability {
        let paths = ["/usr/local/bin/anylinuxfs", "/opt/homebrew/bin/anylinuxfs"]
        let installed = paths.contains { FileManager.default.fileExists(atPath: $0) }
        return BackendCapability(
            kind: .microVM,
            installed: installed,
            ready: installed,
            detail: installed ? "anylinuxfs 已安装" : "隔离兼容后端未安装"
        )
    }
}
