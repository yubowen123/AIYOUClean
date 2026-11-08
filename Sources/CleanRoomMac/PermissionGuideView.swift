import SwiftUI
import AppKit

/// Explains access failures without claiming to know the app's TCC grant state.
/// Every system setting, Finder or clipboard action requires a button click.
@MainActor
struct PermissionGuideView: View {
    let canRescan: Bool
    var rescanTitle = "重新检查"
    let onRescan: () -> Void
    @Environment(\.dismiss) private var dismiss
    private let secondaryText = Color(red: 0.65, green: 0.68, blue: 0.78)
    private let accent = Color(red: 0.61, green: 0.49, blue: 1)

    private var applicationVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未标记版本"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version + (build.map { "（构建\($0)）" } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("处理macOS文件访问受限").font(.title2.weight(.semibold))
            Text("“文件与文件夹”访问可能弹出系统询问，是否弹出由macOS访问规则决定；“完整磁盘访问”需在系统设置中手动添加并启用当前运行版本，不能靠普通授权弹窗或应用代码自动取得。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("拒读也可能来自文件权限、访问控制列表（ACL）或系统保护，不能仅凭一次失败断定缺少完整磁盘访问。授权后仍可能跳过受保护路径，其他可处理候选不受影响。")
                .font(.callout).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text("当前运行版本：\(applicationVersion)").font(.callout.weight(.medium)).textSelection(.enabled)
                Text(Bundle.main.bundleURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("复制版本与应用路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("AIYOUClean \(applicationVersion)\n\(Bundle.main.bundleURL.path)", forType: .string)
                }.font(.caption)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            Text("前往“系统设置 → 隐私与安全性 → 完整磁盘访问”，用＋添加此处定位的应用并启用。如系统提示重新打开应用，请按提示操作后重新扫描实际范围。")
                .font(.caption).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("前往完整磁盘访问") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }
                Button("在Finder中定位当前应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Button(rescanTitle) { dismiss(); onRescan() }.buttonStyle(.borderedProminent).tint(accent).disabled(!canRescan)
            }
            HStack {
                Link("Apple文件访问权限说明", destination: URL(string: "https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox")!).font(.caption)
                Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 690)
    }
}
