import SwiftUI
import AppKit
import CleanRoomCore

private let accent = Color(red: 0.61, green: 0.49, blue: 1)
private let secondaryText = Color(red: 0.65, green: 0.68, blue: 0.78)

struct TrashConfirmationView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("检查本次处理项目", systemImage: "trash").font(.title2.weight(.semibold))
            Text("\(state.selectedItems.count) 项 · \(Format.bytes(state.selectedBytes))")
                .font(.headline).foregroundStyle(accent)
            Text("下面的项目将移到系统废纸篓。清理历史会记录原位置，可在废纸篓内容仍存在且原位置空闲时恢复。")
                .font(.callout).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.selectedItems) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.callout.weight(.medium))
                                Text(item.path).font(.caption.monospaced()).foregroundStyle(secondaryText).textSelection(.enabled)
                            }
                            Spacer(); Text(Format.bytes(item.bytes)).font(.caption).foregroundStyle(secondaryText)
                        }
                        Divider()
                    }
                }.padding(12)
            }.frame(minHeight: 170, maxHeight: 340).background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            Text("重复组会保留至少一份；路径、文件身份或扫描范围不再匹配的项目会被跳过并列出原因。")
                .font(.caption).foregroundStyle(secondaryText)
            HStack {
                Button("取消") { state.showTrashConfirmation = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("移到废纸篓") { state.trashSelected() }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction).disabled(state.detectionUnavailable)
            }
        }.padding(26).frame(width: 650)
    }
}

struct RestoreConfirmationView: View {
    @EnvironmentObject private var state: AppState
    let record: TrashRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("恢复到原位置", systemImage: "arrow.uturn.backward").font(.title2.weight(.semibold))
            Text("原位置").font(.caption).foregroundStyle(secondaryText)
            Text(record.originalPath).font(.callout.monospaced()).textSelection(.enabled)
            Text("废纸篓位置").font(.caption).foregroundStyle(secondaryText)
            Text(record.trashPath).font(.caption.monospaced()).textSelection(.enabled)
            Text("原位置已存在文件、父目录已改变或废纸篓项目已丢失时，恢复会停止，不会覆盖现有文件。")
                .font(.callout).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { state.restoreCandidate = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("恢复文件") { state.restore(record) }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction).disabled(state.detectionUnavailable)
            }
        }.padding(26).frame(width: 620)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                PageHeading(eyebrow: "Keep a way back", title: "清理历史", detail: "记录由本应用移到废纸篓的项目；原位置和废纸篓内容完整时可恢复。")
                Spacer()
                Button { state.reloadHistory() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(state.busy)
            }
            if let warning = state.historyWarning {
                Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if state.history.isEmpty {
                Spacer()
                VStack(spacing: 15) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 46)).foregroundStyle(accent)
                    Text(state.historyWarning == nil ? "还没有清理记录" : "历史记录暂不可用").font(.headline)
                    Text(state.historyWarning == nil ? "扫描不会产生清理记录。只有实际移到废纸篓的项目才会出现在这里。" : "读取或迁移未完成，不能把空列表解释为没有历史记录。请检查上方具体提示。")
                        .font(.callout).foregroundStyle(secondaryText).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.history) { record in
                            Surface {
                                HStack(alignment: .top, spacing: 15) {
                                    Image(systemName: "doc").foregroundStyle(accent).font(.title2)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).font(.headline)
                                        Text(record.originalPath).font(.caption.monospaced()).foregroundStyle(secondaryText).textSelection(.enabled)
                                        Text("\(record.date.formatted(date: .numeric, time: .shortened)) · \(Format.bytes(record.bytes))")
                                            .font(.caption).foregroundStyle(secondaryText)
                                    }
                                    Spacer()
                                    Button("查看") { state.reveal(record.trashPath) }
                                    Button("恢复…") { state.restoreCandidate = record }.disabled(state.detectionUnavailable || !FileManager.default.fileExists(atPath: record.trashPath))
                                }
                            }
                        }
                    }
                }
            }
            if state.busy { ProgressView(state.busyTitle).controlSize(.small) }
            HStack {
                Button("较新记录") { state.newerHistory() }.disabled(state.busy || state.historyPageIndex == 0)
                Text("第 \(state.historyPageIndex + 1) 页 · 每页最多200条").font(.caption).foregroundStyle(secondaryText)
                Button("更早记录") { state.olderHistory() }.disabled(state.busy || !state.historyHasOlder)
                Spacer()
            }
            Text("按需读取历史。如果已手动清空废纸篓，记录可用于核对路径，但文件无法恢复。")
                .font(.caption).foregroundStyle(secondaryText)
        }.padding(30).onAppear { state.reloadHistory() }
    }
}


struct AboutView: View {
    @EnvironmentObject private var state: AppState
    private let groups = [
        "智能检查、本地垃圾与高级清理",
        "应用卸载与残留、大文件与旧文件",
        "重复文件与相似图片候选",
        "空间导航、系统维护与监控",
        "浏览器本地隐私、本地附件与下载",
        "清理历史、扫描设置与忽略清单"
    ]
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                PageHeading(eyebrow: "AIYOUClean", title: "关于 AIYOUClean", detail: "版本 " + version + " · 本地整理与维护工具")
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("可用功能").font(.headline)
                        ForEach(groups, id: \.self) { title in Label(title, systemImage: "checkmark").font(.callout).foregroundStyle(secondaryText) }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("恶意软件检测", systemImage: "shield.checkered").font(.headline)
                        Text("此功能依赖另行安装的 ClamAV 与有效病毒库。引擎和病毒库的当前状态请在检测页核对。")
                            .font(.callout).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
                        Button("查看 ClamAV 状态") { state.destination = .malware }.buttonStyle(.link)
                    }
                }
                Button("设置与忽略清单") { state.destination = .preferences }.buttonStyle(.bordered)
            }.padding(30)
        }
    }
}
