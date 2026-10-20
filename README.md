# OpenNTFS

OpenNTFS 是一个面向 macOS 的开源 NTFS 写入助手。它优先使用隔离的 Linux microVM 后端，把 NTFS 以 NFS 方式映射回 macOS，默认不要求进入恢复模式、不关闭 SIP，也不修改启动安全策略。

> 当前项目仍处于实验性阶段。请先备份重要数据，再在非关键 U 盘上验证。

## 当前状态

已验证：

- 结构化检测外置 NTFS 卷和已安装的第三方驱动；
- SwiftUI 主应用、菜单栏入口和诊断 CLI；
- `anylinuxfs` microVM 后端的管理员授权、失败回滚和真实 NTFS 镜像读写；
- 脏 NTFS 卷的一键修复流程：应用识别内核日志中的 dirty 标记，使用 `anylinuxfs` 自带的 `ntfsfix` 清除标记后自动重试挂载；临时镜像回归已验证 `0x0001 → 0x0000`；
- 修复前通过 `hiberfil.sys` 头识别 Windows 休眠卷，检测到休眠时拒绝修复，不会为了写入而清除休眠状态；
- macOS 27 beta 上的中文卷标兼容处理：内部 NFS 导出名使用 ASCII，真实卷标不变；
- OpenNTFS 自检、XCTest 回归测试，以及 Xcode 应用构建。

尚未完成或仍需验证：

- FSKit 扩展目前只是安全骨架，不能独立接管 NTFS；
- macFUSE/NTFS-3G 仅作为兼容路径检测，不会自动切换正在使用的驱动；
- `ntfs3`、NFS 异步导出与 1MB 读写块的组合尚未在真实 NTFS 卷上完成吞吐和稳定性对比，目前不应据此宣称性能提升；
- 应用内安全推出已改为先卸载 microVM、再推出整盘，但尚未在真实设备上完成回归测试。拔盘前仍请用 `anylinuxfs status` 确认挂载已消失。

## 系统要求

- Apple Silicon Mac（arm64）。`anylinuxfs` 官方仅支持 Apple Silicon，Intel Mac 不在支持范围；
- macOS 15.4 或更新。当前构建和自动测试在 macOS 27.2 上完成，其他系统版本仍需实机验证；
- [Homebrew](https://brew.sh/) 和 `anylinuxfs`。`anylinuxfs 0.18.0` 已验证，更新版本尚未验证；
- 启用写入需要管理员授权。如果磁盘访问被拒绝，需要为 OpenNTFS 开启完全磁盘访问权限。

## 用户安装

1. 安装 `anylinuxfs`：

   ```bash
   brew tap nohajc/anylinuxfs
   brew install anylinuxfs
   ```

2. 从 [GitHub Releases](https://github.com/msln1995/OpenNTFS/releases) 下载 DMG，把 `OpenNTFS.app` 拖入“应用程序”。
3. 当前发布包使用 ad-hoc 签名，未经 Apple 公证。首次启动若被 Gatekeeper 拦截，请右键应用选择“打开”；如果仍然被阻止，可仅对官方下载的副本执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/OpenNTFS.app
   ```

4. 启动应用，确认设备显示为只读后点击“启用写入”。
5. 如果磁盘上次没有在 Windows 中安全弹出，应用会显示“需要修复”。点击“一键修复并启用写入”，确认后应用会自动清除 NTFS 检查标记并重新挂载，不需要使用终端。
6. 如果磁盘处于 Windows 休眠或“快速启动”状态，应用会停止修复并显示处理步骤。请回到 Windows 正常关机后再试，不要绕过该限制。
7. 如果应用提示磁盘访问被拒绝，再到“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中加入 `OpenNTFS.app`，重新打开应用后重试。
8. 成功后，实际挂载点通常是 `~/Volumes/OpenNTFS-diskXsY`，可用以下命令核验：

   ```bash
   anylinuxfs status
   mount | grep -E 'nfs|ntfs'
   ```

不要在未看到 NFS 挂载前创建测试文件，也不要在 microVM 尚未卸载时直接拔盘。

## 从源码构建

需要 Swift 6、完整 Xcode 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)：

```bash
swift run openntfs-selftest
swift test
swift run openntfs --json

xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project OpenNTFS.xcodeproj -scheme OpenNTFS \
  -configuration Debug build
```

如果 Xcode 安装在其他位置，请相应修改 `DEVELOPER_DIR`。只使用命令行工具无法构建 FSKit 目标。

## 安全设计

1. 永不自动操作内部磁盘。
2. 检测到已运行的第三方 NTFS 驱动时保持只读，不让多个驱动竞争同一卷。
3. 写入前先释放 Apple 的只读挂载，失败时尝试恢复原挂载。
4. 管理员密码通过临时 `SUDO_ASKPASS` 脚本输入，不把密码写入日志或命令行参数。
5. 不自动降低 SIP、启动安全策略或要求恢复模式。
6. 应用显示“可写”前会重新读取后端状态，而不是仅依据命令退出码。
7. 写入计划不附加 `-o force`，脏 NTFS 卷必须先通过应用内确认的一键修复，休眠卷直接拒绝修复。
8. 一键修复只处理外置卷，使用 `anylinuxfs` 自带的 `ntfsfix`；运行前检查 `hiberfil.sys`，检测到 Windows 休眠即停止，不修改磁盘。
9. 安全推出先通过 `anylinuxfs unmount --wait-for-vm` 停止 microVM，再推出整盘；任一步失败都不会继续拔盘流程。

## 已知限制

- `anylinuxfs` 使用 NFS 映射，部分应用对网络挂载的文件锁、扩展属性或原子替换支持不完整。
- macOS 对非 ASCII NFS 路径存在兼容问题，因此内部挂载目录使用 ASCII 别名。
- NTFS 卷如果处于 Windows 休眠/快速启动状态，不应写入。OpenNTFS 不会用 `-o force` 绕过该限制，检测到休眠后会拒绝自动修复，请先在 Windows 中完全关机。
- 一键修复清除的是 NTFS 脏标记，不等同于 Windows 的 `chkdsk /f`。如果文件系统仍有错误，Windows 可能仍会要求扫描；修复前请尽量备份重要数据。
- 这是用户态工具，不等同于经过 Apple 签名公证的商业文件系统驱动。

## 项目结构

- `Sources/OpenNTFSCore`：磁盘检测、后端判断、挂载计划和回滚逻辑；
- `Sources/OpenNTFSApp`：SwiftUI 应用和菜单栏界面；
- `Sources/OpenNTFSCLI`：JSON/文本诊断命令；
- `Sources/OpenNTFSSelfTest`：不接触真实磁盘的安全回归自检；
- `Tests/OpenNTFSCoreTests`：XCTest 单元测试；
- `FSKitExtension`：未来 FSKit 实现的受限扩展骨架；
- `Resources`：App Icon 和菜单栏图标资源。

## 贡献

欢迎提交 issue 或 pull request。涉及真实磁盘的改动必须提供：测试镜像回归、失败回滚验证，以及明确说明是否会改变现有用户的挂载方式。请不要在 issue 中上传磁盘镜像、管理员密码或完整系统日志。

## 许可证

本项目使用 MIT License。第三方后端（例如 `anylinuxfs`、NTFS-3G、macFUSE）遵循各自许可证，OpenNTFS 不重新分发这些组件。
