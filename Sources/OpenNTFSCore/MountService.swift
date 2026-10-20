import Foundation

public enum MountServiceError: Error, LocalizedError, Equatable {
    case invalidDeviceIdentifier
    case internalDisk
    case unsupportedBackend
    case backendMissing
    case authorizationFailed(String)
    case ejectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceIdentifier: "磁盘标识不合法，已拒绝执行"
        case .internalDisk: "为保护系统磁盘，禁止启用写入"
        case .unsupportedBackend: "当前后端尚未实现安全挂载"
        case .backendMissing: "免恢复模式后端尚未安装"
        case .authorizationFailed(let message): message.isEmpty ? "管理员授权被取消或挂载失败" : message
        case .ejectFailed(let message): message.isEmpty ? "安全推出失败" : message
        }
    }
}

public struct MountPlan: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let readableDevicePath: String?
    public let releaseMountedDeviceFirst: Bool
    public let targetMountPoint: String?

    public init(
        executable: String,
        arguments: [String],
        readableDevicePath: String? = nil,
        releaseMountedDeviceFirst: Bool = false,
        targetMountPoint: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.readableDevicePath = readableDevicePath
        self.releaseMountedDeviceFirst = releaseMountedDeviceFirst
        self.targetMountPoint = targetMountPoint
    }

}

public struct MountService: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func planEnableWrite(volume: NTFSVolume, backend: BackendKind) throws -> MountPlan {
        try validate(volume)
        guard backend == .microVM else { throw MountServiceError.unsupportedBackend }
        guard let executable = Self.anylinuxfsExecutable() else {
            throw MountServiceError.backendMissing
        }

        // Running anylinuxfs through sudo changes its default mount root to /Volumes.
        // An explicit user-owned target also keeps the NFS mount attributed to this app.
        let mountRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
        let mountPoint = mountRoot
            .appendingPathComponent("OpenNTFS-\(volume.id)", isDirectory: true)

        // 1. 使用 Linux 内核态 ntfs3，避免用户态 FUSE 的额外上下文切换。
        // 2. NFS 服务端异步导出，避免每次 RPC 写都同步落盘。
        // 3. 1MB 的客户端读写块减少 RPC 往返次数。
        // 不附加 -o force：休眠或脏 NTFS 卷必须拒绝写入，而不是绕过一致性检查。
        // 客户端 async 与 locallocks 在这里无效：macOS 默认禁用客户端 async，
        // 且 anylinuxfs 会固定合并 nolocks，无法通过 -n 覆盖。
        let 性能优化参数: [String] = [
            "-t",
            "ntfs3",
            "--nfs-export-opts",
            "rw,async,no_subtree_check,no_root_squash,insecure",
            "-n",
            "wsize=1048576,rsize=1048576,tcp",
        ]

        return MountPlan(
            executable: "/usr/bin/env",
            arguments: privilegeEnvironment + [
                executable,
                "mount",
                "--window",
                "false",
            ] + 性能优化参数 + [
                // -n 接受多个值，没有 -- 时会把磁盘和挂载点当成 NFS 选项。
                "--",
                "/dev/\(volume.id)",
                mountPoint.path,
            ],
            readableDevicePath: "/dev/\(volume.id)",
            releaseMountedDeviceFirst: volume.mountPoint != nil,
            targetMountPoint: mountPoint.path
        )
    }

    public func planDisableWrite(volume: NTFSVolume) throws -> MountPlan {
        try validate(volume)
        guard let executable = Self.anylinuxfsExecutable() else {
            throw MountServiceError.backendMissing
        }
        return MountPlan(
            executable: "/usr/bin/env",
            arguments: privilegeEnvironment + [executable, "unmount", "--wait-for-vm", "/dev/\(volume.id)"]
        )
    }

    public static func wholeDiskIdentifier(for volumeID: String) -> String? {
        guard let match = volumeID.wholeMatch(of: #/^(disk[0-9]+)s[0-9]+$/#) else {
            return nil
        }
        return String(match.1)
    }

    public static func parseStatus(_ output: String) -> [String: String] {
        var mounts: [String: String] = [:]
        for line in output.split(separator: "\n").map(String.init) {
            guard let match = line.wholeMatch(of: #/^\/dev\/(disk[0-9]+s[0-9]+) on (.+) \(.+$/#) else {
                continue
            }
            mounts[String(match.1)] = String(match.2)
        }
        return mounts
    }

    public func safeEject(volume: NTFSVolume) throws -> String {
        try validate(volume)

        var messages: [String] = []
        if try verifiedActiveMountPoints()[volume.id] != nil {
            let unmountPlan = try planDisableWrite(volume: volume)
            let output = try executeAuthorized(unmountPlan)
            if !output.isEmpty {
                messages.append(output)
            }
        }

        guard let wholeDisk = Self.wholeDiskIdentifier(for: volume.id) else {
            throw MountServiceError.invalidDeviceIdentifier
        }
        let eject = try runner.run("/usr/sbin/diskutil", arguments: ["eject", "/dev/\(wholeDisk)"])
        guard eject.status == 0 else {
            throw MountServiceError.ejectFailed(eject.stderrString)
        }
        messages.append(contentsOf: [eject.stdoutString, eject.stderrString])
        return messages
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func executeAuthorized(_ plan: MountPlan) throws -> String {
        if plan.targetMountPoint != nil {
            优化虚拟机硬件配置()
        }

        if let targetMountPoint = plan.targetMountPoint {
            do {
                try FileManager.default.createDirectory(
                    atPath: targetMountPoint,
                    withIntermediateDirectories: true
                )
            } catch {
                throw MountServiceError.authorizationFailed(
                    "无法创建挂载目录 \(targetMountPoint)：\(error.localizedDescription)"
                )
            }
        }

        if plan.releaseMountedDeviceFirst, let path = plan.readableDevicePath {
            let unmount = try runner.run("/usr/sbin/diskutil", arguments: ["unmount", path])
            guard unmount.status == 0 else {
                throw MountServiceError.authorizationFailed(unmount.stderrString)
            }
        }

        do {
            let result = try runWithSudoAskpass(plan)
            guard result.status == 0 else {
                let message = [result.stdoutString, result.stderrString]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw MountServiceError.authorizationFailed(message)
            }
            return [result.stdoutString, result.stderrString]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            restoreReadOnlyMount(for: plan)
            throw error
        }
    }

    // 这是 anylinuxfs 的全局配置，会影响该用户之后的所有挂载；仅在挂载时调整。
    // 默认 1 核/512MB 在网络中断和脏页回收时容易成为瓶颈，这里提升到 4 核/2048MB。
    public func 优化虚拟机硬件配置() {
        guard let 可执行路径 = Self.anylinuxfsExecutable() else { return }
        _ = try? runner.run(可执行路径, arguments: ["config", "-n", "4", "-r", "2048"])
    }

    private func runWithSudoAskpass(_ plan: MountPlan) throws -> CommandResult {
        let askpassURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openntfs-askpass-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        /usr/bin/osascript -e 'tell application "System Events" to display dialog "OpenNTFS 需要管理员权限来挂载或卸载磁盘。" & return & return & "请输入登录密码：" with hidden answer default answer "" buttons {"取消", "确定"} default button "确定" with title "OpenNTFS 授权" with icon caution' -e 'text returned of result' 2>/dev/null
        """
        try Data(script.utf8).write(to: askpassURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassURL.path)
        defer { try? FileManager.default.removeItem(at: askpassURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-A", "--", plan.executable] + plan.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SUDO_ASKPASS"] = askpassURL.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return try ProcessCapture.run(process)
    }

    private func restoreReadOnlyMount(for plan: MountPlan) {
        guard plan.releaseMountedDeviceFirst, let path = plan.readableDevicePath else { return }
        _ = try? runner.run("/usr/sbin/diskutil", arguments: ["mount", path])
    }

    public func activeMountPoints() -> [String: String] {
        guard let executable = Self.anylinuxfsExecutable(),
              let result = try? runner.run(executable, arguments: ["status"]),
              result.status == 0 else {
            return [:]
        }

        return Self.parseStatus(result.stdoutString)
    }

    private func verifiedActiveMountPoints() throws -> [String: String] {
        guard let executable = Self.anylinuxfsExecutable() else { return [:] }

        let result: CommandResult
        do {
            result = try runner.run(executable, arguments: ["status"])
        } catch {
            throw MountServiceError.ejectFailed(
                "无法确认 anylinuxfs 状态，已取消推出：\(error.localizedDescription)"
            )
        }
        guard result.status == 0 else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountServiceError.ejectFailed(
                detail.isEmpty ? "无法确认 anylinuxfs 状态，已取消推出。" : "无法确认 anylinuxfs 状态，已取消推出：\(detail)"
            )
        }
        return Self.parseStatus(result.stdoutString)
    }

    private static func anylinuxfsExecutable() -> String? {
        ["/opt/homebrew/bin/anylinuxfs", "/usr/local/bin/anylinuxfs"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private var privilegeEnvironment: [String] {
        let uid = getuid()
        let gid = getgid()
        let user = NSUserName()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["SUDO_UID=\(uid)", "SUDO_GID=\(gid)", "SUDO_USER=\(user)", "HOME=\(home)"]
    }

    private func validate(_ volume: NTFSVolume) throws {
        guard !volume.isInternal else { throw MountServiceError.internalDisk }
        guard volume.id.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            throw MountServiceError.invalidDeviceIdentifier
        }
    }
}
