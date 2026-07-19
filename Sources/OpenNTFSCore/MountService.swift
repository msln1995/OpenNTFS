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

    public var shellCommand: String {
        let command = ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
        guard let readableDevicePath else { return command }
        let path = Self.shellQuote(readableDevicePath)
        let preflight = "test -r \(path) || { echo OPENNTFS_FULL_DISK_ACCESS_REQUIRED; exit 77; }"
        guard releaseMountedDeviceFirst else {
            return "\(preflight); \(command)"
        }
        let unmount = "/usr/sbin/diskutil unmount \(path)"
        let restore = "/usr/sbin/diskutil mount \(path) >/dev/null 2>&1"
        return "\(unmount) && \(preflight) && \(command) || { rc=$?; \(restore); exit $rc; }"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        let executable = ["/opt/homebrew/bin/anylinuxfs", "/usr/local/bin/anylinuxfs"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let executable else { throw MountServiceError.backendMissing }

        // Running anylinuxfs through sudo changes its default mount root to /Volumes.
        // An explicit user-owned target also keeps the NFS mount attributed to this app.
        let mountRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
        let mountPoint = mountRoot
            .appendingPathComponent("OpenNTFS-\(volume.id)", isDirectory: true)

        return MountPlan(
            executable: "/usr/bin/env",
            arguments: privilegeEnvironment + [
                executable,
                "mount",
                "--window",
                "false",
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
        let executable = ["/opt/homebrew/bin/anylinuxfs", "/usr/local/bin/anylinuxfs"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let executable else { throw MountServiceError.backendMissing }
        return MountPlan(
            executable: "/usr/bin/env",
            arguments: privilegeEnvironment + [executable, "unmount", "--wait-for-vm", "/dev/\(volume.id)"]
        )
    }

    public func safeEject(volume: NTFSVolume) throws -> String {
        try validate(volume)
        let mounts = activeMountPoints()
        if let mountPoint = mounts[volume.id] {
            let result = try runner.run("/sbin/umount", arguments: [mountPoint])
            guard result.status == 0 else {
                throw MountServiceError.ejectFailed(result.stderrString)
            }
        }

        let wholeDisk = volume.id.split(separator: "s", maxSplits: 1).first.map(String.init)
            ?? volume.id
        let eject = try runner.run("/usr/sbin/diskutil", arguments: ["eject", "/dev/\(wholeDisk)"])
        guard eject.status == 0 else {
            throw MountServiceError.ejectFailed(eject.stderrString)
        }
        return [eject.stdoutString, eject.stderrString]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func executeAuthorized(_ plan: MountPlan) throws -> String {
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

    private func runWithSudoAskpass(_ plan: MountPlan) throws -> CommandResult {
        let askpassURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openntfs-askpass-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        /usr/bin/osascript -e 'tell application "System Events" to display dialog "OpenNTFS 需要管理员权限来挂载磁盘。" & return & return & "请输入登录密码：" with hidden answer default answer "" buttons {"取消", "确定"} default button "确定" with title "OpenNTFS 授权" with icon caution' -e 'text returned of result' 2>/dev/null
        """
        try Data(script.utf8).write(to: askpassURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassURL.path)
        defer { try? FileManager.default.removeItem(at: askpassURL) }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-A", "--", plan.executable] + plan.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SUDO_ASKPASS"] = askpassURL.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: error.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func restoreReadOnlyMount(for plan: MountPlan) {
        guard plan.releaseMountedDeviceFirst, let path = plan.readableDevicePath else { return }
        _ = try? runner.run("/usr/sbin/diskutil", arguments: ["mount", path])
    }

    public func activeMountPoints() -> [String: String] {
        let executable = ["/opt/homebrew/bin/anylinuxfs", "/usr/local/bin/anylinuxfs"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let executable,
              let result = try? runner.run(executable, arguments: ["status"]),
              result.status == 0 else {
            return [:]
        }

        var mounts: [String: String] = [:]
        for line in result.stdoutString.split(separator: "\n").map(String.init) {
            guard let match = line.wholeMatch(of: #/^\/dev\/(disk[0-9]+s[0-9]+) on (.+) \(.+$/#) else {
                continue
            }
            mounts[String(match.1)] = String(match.2)
        }
        return mounts
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
