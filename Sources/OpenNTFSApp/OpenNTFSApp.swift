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
    var needsFullDiskAccessVolumeIDs: Set<String> = []

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
            operationMessages[volume.id] = "写入模式已启用：\(writeMountPoints[volume.id] ?? "")"
            needsFullDiskAccessVolumeIDs.remove(volume.id)
        } catch {
            writeEnabledVolumeIDs.remove(volume.id)
            operationMessages[volume.id] = error.localizedDescription
            if error.localizedDescription.contains("OPENNTFS_FULL_DISK_ACCESS_REQUIRED") ||
                error.localizedDescription.localizedCaseInsensitiveContains("insufficient permissions") {
                needsFullDiskAccessVolumeIDs.insert(volume.id)
                operationMessages[volume.id] = "需要为 OpenNTFS 开启完全磁盘访问权限，然后重新打开应用。"
            }
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: volume.isWritable || writeEnabled ? "checkmark.circle.fill" : "lock.fill")
                            .foregroundStyle(volume.isWritable || writeEnabled ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(volume.name).font(.title3.bold())
                            Text(volume.mountPoint ?? "未挂载").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(volume.isWritable || writeEnabled ? "可写" : "只读")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(volume.isWritable || writeEnabled ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(recommendation?.title ?? "正在检查")
                        .font(.headline)
                    Text(recommendation?.explanation ?? "")
                        .foregroundStyle(.secondary)
                    if let message = model.operationMessages[volume.id] {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(writeEnabled ? .green : .secondary)
                            .textSelection(.enabled)
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
                        Button(writeEnabled ? "写入已启用" : "启用写入", systemImage: writeEnabled ? "checkmark.circle" : "pencil.and.outline") {
                            Task { await model.enableWrite(volume: volume) }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.mountingVolumeID != nil ||
                                writeEnabled ||
                                recommendation?.safety != .safe ||
                                recommendation?.backend == .unavailable
                            )
                        Button("在 Finder 中打开", systemImage: "folder") {
                            if let path = model.writeMountPoints[volume.id] ?? volume.mountPoint {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        }
                        .disabled(model.writeMountPoints[volume.id] == nil && volume.mountPoint == nil)
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
                    Label("\(volume.name) · \(volume.isWritable ? "可写" : "只读")", systemImage: "externaldrive")
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
