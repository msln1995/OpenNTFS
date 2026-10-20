import AppKit
import Observation
import SwiftUI
import OpenNTFSCore

@main
struct OpenNTFSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("OpenNTFS") {
            ContentView(model: model)
                .frame(minWidth: 680, minHeight: 500)
                .task { await model.refresh() }
        }
        .defaultSize(width: 760, height: 560)

        MenuBarExtra("OpenNTFS", image: "MenuBarIcon") {
            MenuBarView(model: model)
                .task { await model.refresh() }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var snapshot: SystemSnapshot?
    var recommendations: [String: VolumeRecommendation] = [:]
    var errorMessage: String?
    var isRefreshing = false
    var mountingVolumeID: String?
    var writeEnabledVolumeIDs: Set<String> = []
    var writeMountPoints: [String: String] = [:]
    var operationMessages: [String: String] = [:]
    var technicalDetails: [String: String] = [:]
    var volumeIssues: [String: NTFSVolumeIssue] = [:]
    var needsFullDiskAccessVolumeIDs: Set<String> = []
    var ejectingVolumeID: String?
    var repairingVolumeID: String?
    var restoringVolumeID: String?
    var pendingRepairVolume: NTFSVolume?
    var pendingEjectVolume: NTFSVolume?

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let value = try await Task.detached { try SystemInspector().snapshot() }.value
            let engine = RecommendationEngine()
            snapshot = value
            recommendations = Dictionary(uniqueKeysWithValues: value.volumes.map {
                ($0.id, engine.recommend(volume: $0, capabilities: value.backends, conflicts: value.conflicts))
            })
            let activeMounts = await Task.detached { MountService().activeMountPoints() }.value
            writeMountPoints = activeMounts
            writeEnabledVolumeIDs = Set(activeMounts.keys)
            let volumeIDs = Set(value.volumes.map(\.id))
            volumeIssues = volumeIssues.filter { volumeIDs.contains($0.key) }
            operationMessages = operationMessages.filter { volumeIDs.contains($0.key) }
            technicalDetails = technicalDetails.filter { volumeIDs.contains($0.key) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func enableWrite(volume: NTFSVolume) async {
        guard let recommendation = recommendations[volume.id] else { return }
        mountingVolumeID = volume.id
        operationMessages[volume.id] = "正在请求管理员授权…"
        defer { mountingVolumeID = nil }
        do {
            let plan = try MountService().planEnableWrite(volume: volume, backend: recommendation.backend)
            let output = try await Task.detached { try MountService().executeAuthorized(plan) }.value
            await refresh()
            guard writeEnabledVolumeIDs.contains(volume.id) else {
                throw MountServiceError.authorizationFailed(output.isEmpty ? "挂载命令结束，但没有发现可写挂载点" : output)
            }
            volumeIssues.removeValue(forKey: volume.id)
            technicalDetails.removeValue(forKey: volume.id)
            operationMessages[volume.id] = "写入模式已启用：\(writeMountPoints[volume.id] ?? "")"
            needsFullDiskAccessVolumeIDs.remove(volume.id)
        } catch {
            writeEnabledVolumeIDs.remove(volume.id)
            let details = error.localizedDescription
            technicalDetails[volume.id] = details
            let issue = await Task.detached {
                MountService().diagnoseMountFailure(output: details)
            }.value
            if let issue {
                volumeIssues[volume.id] = issue
                operationMessages[volume.id] = Self.issueMessage(for: issue)
                needsFullDiskAccessVolumeIDs.remove(volume.id)
                return
            }
            operationMessages[volume.id] = "无法启用写入。请确认磁盘没有在 Windows 中使用，然后重试。"
            if details.localizedCaseInsensitiveContains("operation not permitted") ||
                details.localizedCaseInsensitiveContains("permission denied") ||
                details.localizedCaseInsensitiveContains("insufficient permissions") {
                needsFullDiskAccessVolumeIDs.insert(volume.id)
                operationMessages[volume.id] = "磁盘访问被拒绝。请检查完全磁盘访问权限和 anylinuxfs 安装状态，然后重试。"
            }
        }
    }

    func repairAndEnableWrite(volume: NTFSVolume) async {
        guard volumeIssues[volume.id] == .dirty else { return }
        guard mountingVolumeID == nil,
              repairingVolumeID == nil,
              ejectingVolumeID == nil,
              restoringVolumeID == nil
        else { return }
        repairingVolumeID = volume.id
        operationMessages[volume.id] = "正在修复磁盘，请不要拔出…"
        defer { repairingVolumeID = nil }

        do {
            let plan = try MountService().planRepairDirtyVolume(volume: volume)
            let output = try await Task.detached { try MountService().executeAuthorized(plan) }.value
            let outcome = MountService.parseRepairOutcome(output) ?? .failed
            await applyRepairOutcome(outcome, volume: volume, details: output)
        } catch {
            let details = error.localizedDescription
            technicalDetails[volume.id] = details
            if let outcome = MountService.parseRepairOutcome(details) {
                await applyRepairOutcome(outcome, volume: volume, details: details)
            } else {
                operationMessages[volume.id] = "自动修复没有完成。你可以重试；如果仍然失败，请到 Windows 中运行磁盘检查。"
            }
        }
    }

    private func applyRepairOutcome(
        _ outcome: DirtyVolumeRepairOutcome,
        volume: NTFSVolume,
        details: String
    ) async {
        switch outcome {
        case .hibernated:
            technicalDetails[volume.id] = details
            volumeIssues[volume.id] = .hibernated
            operationMessages[volume.id] = "这个磁盘正被 Windows 休眠占用。请回到 Windows 正常关机后再试。"
        case .failed:
            technicalDetails[volume.id] = details
            volumeIssues[volume.id] = .dirty
            operationMessages[volume.id] = "自动修复没有成功。请重试，或到 Windows 中运行磁盘检查。"
        case .repaired:
            operationMessages[volume.id] = "修复完成，正在重新挂载…"
            await refresh()
            guard let freshVolume = snapshot?.volumes.first(where: { $0.id == volume.id }) else {
                operationMessages[volume.id] = "磁盘已修复，但找不到设备。请重新插拔后再试。"
                return
            }
            volumeIssues.removeValue(forKey: volume.id)
            await enableWrite(volume: freshVolume)
            if writeEnabledVolumeIDs.contains(volume.id) {
                technicalDetails.removeValue(forKey: volume.id)
                operationMessages[volume.id] = "已修复并启用写入：\(writeMountPoints[volume.id] ?? "")"
            } else if volumeIssues[volume.id] == nil {
                operationMessages[volume.id] = "磁盘已修复，但写入挂载没有成功。请重试。"
            }
        }
    }

    private static func issueMessage(for issue: NTFSVolumeIssue) -> String {
        switch issue {
        case .dirty:
            "这个磁盘上次没有正常结束写入。请使用下方的一键修复，清除检查标记后再启用写入。"
        case .hibernated:
            "这个磁盘正被 Windows 休眠占用。请回到 Windows 正常关机后再试，OpenNTFS 不会自动修改它。"
        }
    }

    func restoreReadOnly(volume: NTFSVolume) async {
        guard mountingVolumeID == nil,
              repairingVolumeID == nil,
              ejectingVolumeID == nil,
              restoringVolumeID == nil
        else { return }
        restoringVolumeID = volume.id
        operationMessages[volume.id] = "正在退出写入模式并恢复 macOS 只读挂载…"
        defer { restoringVolumeID = nil }
        do {
            let mountPoint = try await Task.detached {
                try MountService().restoreReadOnlyMount(volume: volume)
            }.value
            writeEnabledVolumeIDs.remove(volume.id)
            writeMountPoints.removeValue(forKey: volume.id)
            operationMessages[volume.id] = "已恢复 macOS 只读挂载：\(mountPoint)"
            await refresh()
        } catch {
            operationMessages[volume.id] = "恢复只读挂载失败：\(error.localizedDescription)"
            await refresh()
        }
    }

    func safeEject(volume: NTFSVolume) async {
        ejectingVolumeID = volume.id
        operationMessages[volume.id] = "正在安全推出…"
        defer { ejectingVolumeID = nil }
        do {
            _ = try await Task.detached { try MountService().safeEject(volume: volume) }.value
            writeEnabledVolumeIDs.remove(volume.id)
            writeMountPoints.removeValue(forKey: volume.id)
            operationMessages[volume.id] = "已安全推出，可以拔出设备。桌面图标消失是正常的；若还要继续使用，请拔下后重新插入。"
            await refresh()
        } catch {
            operationMessages[volume.id] = error.localizedDescription
            await refresh()
        }
    }
}

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("NTFS 设备") {
                    if let volumes = model.snapshot?.volumes, !volumes.isEmpty {
                        ForEach(volumes) { volume in
                            Label(volume.name, systemImage: "externaldrive.fill")
                        }
                    } else {
                        ContentUnavailableView("没有检测到 NTFS 设备", systemImage: "externaldrive.badge.questionmark")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    volumeSection
                    diagnosticsSection
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        .alert(
            "修复并启用写入？",
            isPresented: Binding(
                get: { model.pendingRepairVolume != nil },
                set: { if !$0 { model.pendingRepairVolume = nil } }
            ),
            presenting: model.pendingRepairVolume
        ) { volume in
            Button("取消", role: .cancel) {
                model.pendingRepairVolume = nil
            }
            Button("开始修复", role: .destructive) {
                model.pendingRepairVolume = nil
                Task { await model.repairAndEnableWrite(volume: volume) }
            }
        } message: { _ in
            Text("OpenNTFS 将清除 Windows 留下的磁盘检查标记，然后重新挂载为可写。这不会删除文件，但修复前请尽量备份重要数据。如果磁盘处于 Windows 休眠状态，修复会自动停止。")
        }
        .alert(
            "安全推出设备？",
            isPresented: Binding(
                get: { model.pendingEjectVolume != nil },
                set: { if !$0 { model.pendingEjectVolume = nil } }
            ),
            presenting: model.pendingEjectVolume
        ) { volume in
            Button("取消", role: .cancel) {
                model.pendingEjectVolume = nil
            }
            Button("安全推出") {
                model.pendingEjectVolume = nil
                Task { await model.safeEject(volume: volume) }
            }
        } message: { volume in
            if model.writeEnabledVolumeIDs.contains(volume.id) {
                Text("这会停止 OpenNTFS 写入，并把整块磁盘从系统移除。桌面图标会消失，适合准备拔下 U 盘时使用。如果只是想退出写入模式、继续使用文件，请取消并点“恢复只读”。")
            } else {
                Text("这会把整块磁盘从系统移除，桌面图标会消失。适合准备拔下设备时使用；若要继续使用文件，请取消。")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OpenNTFS")
                .font(.largeTitle.bold())
            Text("默认不进入恢复模式，不降低系统安全设置。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var volumeSection: some View {
        if let volumes = model.snapshot?.volumes, !volumes.isEmpty {
            ForEach(volumes) { volume in
                let recommendation = model.recommendations[volume.id]
                let writeEnabled = model.writeEnabledVolumeIDs.contains(volume.id)
                let issue = model.volumeIssues[volume.id]
                let isWritableNow = volume.isWritable || writeEnabled
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: isWritableNow
                            ? "checkmark.circle.fill"
                            : (issue == .dirty ? "wrench.and.screwdriver.fill" : (issue == .hibernated ? "moon.zzz.fill" : "lock.fill")))
                            .foregroundStyle(isWritableNow ? .green : (issue == .hibernated ? .red : .orange))
                        VStack(alignment: .leading) {
                            Text(volume.name).font(.title3.bold())
                            Text(volume.mountPoint ?? "未挂载").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(isWritableNow ? "可写" : (issue == .dirty ? "需要修复" : (issue == .hibernated ? "休眠占用" : "只读")))
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isWritableNow ? Color.green.opacity(0.15) : (issue == .hibernated ? Color.red.opacity(0.15) : Color.orange.opacity(0.15)))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(recommendation?.title ?? "正在检查")
                        .font(.headline)
                    Text(recommendation?.explanation ?? "")
                        .foregroundStyle(.secondary)
                    if issue == .dirty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("这个磁盘需要先修复", systemImage: "wrench.and.screwdriver.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("上次 Windows 没有正常关机或安全弹出时，磁盘会留下“需要检查”标记。清除标记后才能安全写入。修复不会删除文件，但请先备份重要数据。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button {
                                model.pendingRepairVolume = volume
                            } label: {
                                Label(
                                    model.repairingVolumeID == volume.id ? "正在修复…" : "一键修复并启用写入",
                                    systemImage: model.repairingVolumeID == volume.id ? "hourglass" : "wrench.and.screwdriver"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.repairingVolumeID != nil || model.mountingVolumeID != nil || model.ejectingVolumeID != nil)
                            Text("如果磁盘被 Windows 休眠或“快速启动”占用，修复会自动停止，不会修改磁盘。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if issue == .hibernated {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("这个磁盘正被 Windows 休眠占用", systemImage: "moon.zzz.fill")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text("为防止损坏文件，OpenNTFS 不会自动修复或写入。请回到 Windows 正常关机（不是睡眠或休眠），再重新连接磁盘。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            DisclosureGroup("在 Windows 上怎么处理？") {
                                Text("1. 把磁盘接回 Windows。\n2. 在开始菜单中选择“关机”，不要选择“睡眠”或“休眠”。\n3. 如果仍然出现此提示，打开“控制面板 → 电源选项 → 选择电源按钮的功能 → 更改当前不可用的设置”，取消“启用快速启动”，保存后再次关机。\n4. 安全弹出磁盘，再连接到 Mac。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            .font(.callout)
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let message = model.operationMessages[volume.id] {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(writeEnabled ? .green : (issue == nil ? .secondary : .orange))
                            .textSelection(.enabled)
                    }
                    if let details = model.technicalDetails[volume.id] {
                        DisclosureGroup("技术细节") {
                            ScrollView {
                                Text(details)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                        .font(.caption)
                    }
                    if model.needsFullDiskAccessVolumeIDs.contains(volume.id) {
                        Button("打开完全磁盘访问设置", systemImage: "gear") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        if issue == nil {
                            if writeEnabled {
                                Button("恢复只读", systemImage: "arrow.uturn.backward") {
                                    Task { await model.restoreReadOnly(volume: volume) }
                                }
                                .buttonStyle(.borderedProminent)
                            } else if volume.mountPoint == nil, !volume.isInternal {
                                Button("挂载为只读", systemImage: "externaldrive") {
                                    Task { await model.restoreReadOnly(volume: volume) }
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button("启用写入", systemImage: "pencil.and.outline") {
                                    Task { await model.enableWrite(volume: volume) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    recommendation?.safety != .safe ||
                                    recommendation?.backend == .unavailable
                                )
                            }
                        }
                        Button("在 Finder 中打开", systemImage: "folder") {
                            if let path = model.writeMountPoints[volume.id] ?? volume.mountPoint {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        }
                        .disabled(model.writeMountPoints[volume.id] == nil && volume.mountPoint == nil)
                        Button(writeEnabled ? "安全推出（拔盘）" : "安全推出", systemImage: "eject") {
                            model.pendingEjectVolume = volume
                        }
                        .help("停止 OpenNTFS 写入并从系统推出整盘。推出后桌面图标会消失，重新插拔才会再次出现。")
                        .disabled(
                            model.ejectingVolumeID != nil ||
                            model.mountingVolumeID != nil ||
                            model.repairingVolumeID != nil ||
                            model.restoringVolumeID != nil
                        )
                    }
                    .disabled(
                        model.mountingVolumeID != nil ||
                        model.repairingVolumeID != nil ||
                        model.restoringVolumeID != nil
                    )
                    if writeEnabled {
                        Text("“恢复只读”会停止 OpenNTFS 写入并把磁盘交回 macOS；“安全推出（拔盘）”会从系统移除整盘，适合准备拔下 U 盘时使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(.quaternary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("后端与冲突检测").font(.headline)
            ForEach(model.snapshot?.backends ?? [], id: \.kind) { backend in
                HStack {
                    Image(systemName: backend.ready ? "checkmark.circle" : "circle.dashed")
                    Text(backend.kind.displayName)
                    Spacer()
                    Text(backend.detail).foregroundStyle(.secondary)
                }
            }
            ForEach(model.snapshot?.conflicts ?? [], id: \.self) { conflict in
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(model.snapshot?.notices ?? [], id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}

struct MenuBarView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenNTFS").font(.headline)
            if let volumes = model.snapshot?.volumes, !volumes.isEmpty {
                ForEach(volumes) { volume in
                    let status: String = if let issue = model.volumeIssues[volume.id] {
                        issue == .dirty ? "需要修复" : "被 Windows 休眠占用"
                    } else {
                        volume.isWritable || model.writeEnabledVolumeIDs.contains(volume.id) ? "可写" : "只读"
                    }
                    Label("\(volume.name) · \(status)", systemImage: "externaldrive")
                }
            } else {
                Text("没有 NTFS 设备").foregroundStyle(.secondary)
            }
            Divider()
            Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            Button("退出", systemImage: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }
}
