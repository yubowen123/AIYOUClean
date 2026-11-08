import SwiftUI
import CleanRoomCore

private let accent = Color(red: 0.61, green: 0.49, blue: 1)
private let secondaryText = Color(red: 0.65, green: 0.68, blue: 0.78)

struct MainView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                VStack(spacing: 0) {
                    DetectionActivityBar(tasks: state.taskCenter) { state.destination = $0 }
                    ZStack {
                    LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.17), Color(red: 0.045, green: 0.055, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                    switch state.destination {
                    case .dashboard: DashboardView()
                    case .smartCare: SmartCareView(registry: state.featureStates)
                    case .scan(.spaceLens): SpaceLensView(registry: state.featureStates)
                    case .scan: ScanView()
                    case .maintenance: OperationsView(registry: state.featureStates)
                    case .malware: MalwareView(registry: state.featureStates)
                    case .monitor: MonitorView()
                    case .advancedCleanup: AdvancedCleanupView(registry: state.featureStates)
                    case .privacy: BrowserPrivacyView(registry: state.featureStates)
                    case .history: HistoryView()
                    case .about: AboutView()
                    case .preferences: PreferencesView()
                    case nil: DashboardView()
                    }
                    }
                }
            }
            .tint(accent)
        }
        .onAppear { state.resumePresentation() }
        .onDisappear { state.suspendPresentation() }
        .alert("操作结果", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("好") { state.message = nil }
        } message: { Text(state.message ?? "") }
        .sheet(isPresented: $state.showTrashConfirmation) { TrashConfirmationView() }
        .sheet(item: $state.restoreCandidate) { record in RestoreConfirmationView(record: record) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 25)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AIYOUClean").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("让空间更清晰").font(.caption).foregroundStyle(secondaryText)
                }
            }.padding(.horizontal, 19).padding(.top, 23).padding(.bottom, 22)
            List(selection: $state.destination) {
                Label("总览", systemImage: "rectangle.3.group").tag(Destination.dashboard)
                Label("智能检查", systemImage: "sparkle.magnifyingglass").tag(Destination.smartCare)
                Section("整理与清理") {
                    nav(.cleanup)
                    Label("高级清理", systemImage: "slider.horizontal.below.square.filled.and.square").tag(Destination.advancedCleanup)
                    nav(.largeFiles); nav(.duplicates); nav(.similarImages); nav(.downloads); nav(.spaceLens)
                }
                Section("应用与系统") {
                    nav(.applications); nav(.leftovers)
                    nav(.protection)
                    Label("恶意软件检测", systemImage: "shield.checkered").tag(Destination.malware)
                    Label("系统监控", systemImage: "waveform.path.ecg").tag(Destination.monitor)
                    Label("维护工具", systemImage: "slider.horizontal.3").tag(Destination.maintenance)
                }
                Section("更多文件") {
                    nav(.aiModels); nav(.mailAttachments)
                }
                Section {
                    Label("清理历史", systemImage: "clock.arrow.circlepath").tag(Destination.history)
                    Label("浏览器本地隐私", systemImage: "hand.raised").tag(Destination.privacy)
                    Label("设置与忽略清单", systemImage: "line.3.horizontal.decrease.circle").tag(Destination.preferences)
                    Label("关于 AIYOUClean", systemImage: "info.circle").tag(Destination.about)
                }
            }
            .listStyle(.sidebar).accessibilityIdentifier("navigation.sidebar")
            VStack(alignment: .leading, spacing: 5) {
                Text("本地处理 · 可审阅操作").font(.caption.weight(.medium))
                Text("默认只扫描；处理前检查具体项目与范围。")
                    .font(.caption2).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
            }.padding(18)
        }
        .background(Color(red: 0.07, green: 0.075, blue: 0.13))
        .navigationSplitViewColumnWidth(min: 225, ideal: 235, max: 270)
    }
    @ViewBuilder private func nav(_ kind: ScanKind) -> some View {
        if ProductFeatures.allows(kind) { Label(ProductFeatures.title(for: kind), systemImage: kind.symbol).tag(Destination.scan(kind)) }
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(accent)
            Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
            Text(detail).font(.system(size: 13)).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "Your Mac, in focus", title: "空间有序，工作从容。", detail: "从一次只读扫描开始，了解文件占用与系统状态。")
                    Spacer()
                    Button { state.refreshSystem() } label: { Label("刷新状态", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                }
                hero
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    stat("系统内存总量", value: state.memoryText(state.snapshot.totalMemory), icon: "memorychip")
                    stat("AIYOUClean 进程内存", value: state.processResidentBytes.map { state.memoryText($0) } ?? "未读取到", icon: "app.badge")
                    stat("处理器", value: "\(state.snapshot.processors) 核", icon: "cpu")
                    stat("电池", value: state.batterySummary, icon: "battery.100")
                }
                Text("进程内存随状态刷新采样，显示驻留内存（RSS）；与系统内存总量分别列出。")
                    .font(.caption).foregroundStyle(secondaryText)
                VStack(alignment: .leading, spacing: 14) {
                    Text("从这里开始").font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        quick(.cleanup, subtitle: "检查用户缓存、日志和开发缓存")
                        quick(.duplicates, subtitle: "按内容校验，查找重复占用")
                        quick(.applications, subtitle: "应用与对应支持文件清单")
                        quick(.spaceLens, subtitle: "看清文件夹的空间分布")
                    }
                }
                Surface {
                    HStack(alignment: .top, spacing: 15) {
                        Image(systemName: "info.circle").font(.title2).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("先检查，再处理").font(.headline)
                            Text("扫描不会自动删除文件。选择项目后，检查具体路径与操作范围；想保留的内容可加入忽略清单。")
                                .font(.callout).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
                            Button("管理忽略清单") { state.destination = .preferences }.buttonStyle(.link)
                        }
                    }
                }
                Text("\(state.snapshot.host) · \(state.snapshot.os) · 系统负载 \(state.snapshot.loadAverage)")
                    .font(.caption).foregroundStyle(secondaryText).textSelection(.enabled)
            }.padding(32)
        }
    }
    private var hero: some View {
        HStack(spacing: 32) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 16)
                Circle().trim(from: 0, to: usedFraction).stroke(AngularGradient(colors: [Color.cyan, accent, Color.pink], center: .center), style: StrokeStyle(lineWidth: 16, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 6) {
                    Text(Format.bytes(state.snapshot.availableDisk)).font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("可用空间").font(.caption).foregroundStyle(secondaryText)
                }
            }.frame(width: 170, height: 170)
            VStack(alignment: .leading, spacing: 15) {
                Text("给重要的事，多留一点空间。")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("卷总容量 \(Format.bytes(state.snapshot.totalDisk))\n可用容量由系统返回；APFS 共享容器与可清除空间可能影响显示。")
                    .font(.callout).foregroundStyle(secondaryText).lineSpacing(4)
                Button { state.destination = .smartCare } label: {
                    Label("开始智能检查", systemImage: "sparkles").padding(.horizontal, 12).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).tint(accent)
            }
            Spacer(minLength: 0)
        }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [accent.opacity(0.15), Color.blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(accent.opacity(0.2)))
    }
    private var usedFraction: CGFloat {
        guard state.snapshot.totalDisk > 0 else { return 0 }
        return CGFloat(max(0, min(1, Double(state.snapshot.totalDisk - state.snapshot.availableDisk) / Double(state.snapshot.totalDisk))))
    }
    private func stat(_ title: String, value: String, icon: String) -> some View {
        Surface {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.caption).foregroundStyle(secondaryText)
                    Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(2)
                }
                Spacer(minLength: 5)
                Image(systemName: icon).foregroundStyle(accent).font(.title2)
            }
        }
    }
    private func quick(_ kind: ScanKind, subtitle: String) -> some View {
        Button { state.navigate(kind) } label: {
            Surface {
                HStack(spacing: 14) {
                    Image(systemName: kind.symbol).font(.system(size: 23)).foregroundStyle(accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ProductFeatures.title(for: kind)).font(.headline).foregroundStyle(.white)
                        Text(subtitle).font(.caption).foregroundStyle(secondaryText)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(secondaryText)
                }
            }
        }.buttonStyle(.plain)
    }
}

struct ScanView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingAccessGuide = false
    var body: some View {
        if let kind = state.kind {
            GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(eyebrow: "Inspect before you act", title: ProductFeatures.title(for: kind), detail: kind.detail)
                scopeBar
                if state.isCurrentScanRunning { scanningProgress }
                if let report = state.report {
                    warnings(report)
                    resultToolbar(report)
                    if state.pageLoading { loadingPage }
                    else if let error = state.pageError { pageFailure(error) }
                    else if state.visibleItems.isEmpty { emptyResult(report) } else { results(kind) }
                } else if !state.isCurrentScanRunning {
                    Spacer()
                    VStack(spacing: 18) {
                        Image(systemName: kind.symbol).font(.system(size: 55, weight: .light)).foregroundStyle(accent)
                        Text("先了解，再整理").font(.title2.weight(.semibold))
                        Text(usesRoots ? "扫描只读取文件信息。扫描结果需要你逐项选择后，才会执行移到废纸篓。" : "检查本机安全设置与状态。此页只读，不执行清理或恶意软件检测。")
                            .font(.callout).foregroundStyle(secondaryText).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Button("开始扫描") { state.scan() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(state.detectionUnavailable)
                    }.frame(maxWidth: .infinity)
                    Spacer()
                }
            }.padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.report != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        paginationBar
                        if usesRoots { selectionBar }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.065, green: 0.075, blue: 0.13))
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .onDisappear { state.clearSelection(); state.showTrashConfirmation = false }
            .sheet(isPresented: $showingAccessGuide) {
                PermissionGuideView(canRescan: !state.detectionUnavailable, rescanTitle: "重新扫描当前范围") { state.scan() }
            }
        }
    }
    private var usesRoots: Bool { state.kind != .protection }
    private var scopeTitle: String {
        if state.kind == .protection { return "本机安全设置（不使用文件夹范围）" }
        return state.roots.isEmpty ? "模块默认范围" : "自选 \(state.roots.count) 个文件夹"
    }
    private var scopeBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scopeTitle).font(.callout.weight(.medium))
                    if usesRoots && !state.roots.isEmpty { Text(state.roots.map(\.path).joined(separator: " · ")).font(.caption).foregroundStyle(secondaryText).lineLimit(1).help(state.roots.map(\.path).joined(separator: "\n")) }
                }
                Spacer()
                Button("选择文件夹…") { state.chooseRoots() }.disabled(state.detectionUnavailable || state.kind == .protection)
                if usesRoots && !state.roots.isEmpty { Button("恢复默认") { state.resetRoots() }.disabled(state.detectionUnavailable) }
                Button { state.scan() } label: { Label(state.report == nil ? "扫描" : "重新扫描", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).disabled(state.detectionUnavailable)
            }
            if usesRoots {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Label("持续检索到完成；结果保存在磁盘，每页显示200项。可随时取消。", systemImage: "externaldrive")
                        .font(.caption).foregroundStyle(secondaryText).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("访问权限引导…") { showingAccessGuide = true }.font(.caption)
                        .help("查看手动授权步骤、当前运行应用的版本与路径")
                }
            }
        }.padding(15).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
    private var scanningProgress: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.isScanning ? "\(state.busyTitle) · 已检查 \(state.progressCount) 项" : state.busyTitle).font(.callout.weight(.medium))
                Text(state.isScanning ? state.progressPath : "等待系统完成当前操作…").font(.caption).foregroundStyle(secondaryText).lineLimit(1)
            }
            Spacer()
            Button("取消") { state.cancelScan() }.disabled(!state.isScanning)
        }.padding(13).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private func warnings(_ report: ScanReport) -> some View {
        if report.stopReason != nil || report.truncated || !report.warnings.isEmpty {
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if let reason = report.stopReason { Text(reason.title) }
                        else if report.truncated { Text("部分路径未完成检查，查看具体提示。") }
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in Text("• " + warning).textSelection(.enabled) }
                        if hasAccessWarnings(report) {
                            Text("macOS 拒绝访问的路径不会被绕过。已完成检查且可处理的项目仍可逐项选择；未检查的目录不能整体清理。")
                            Text("可通过访问引导检查设置；拒读也可能来自文件权限、ACL或系统保护，开启完整磁盘访问不保证所有路径都可读取。")
                        }
                    }.font(.caption).foregroundStyle(secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                }.frame(maxHeight: 140)
            } label: {
                Label(report.stopReason?.title ?? (report.truncated ? "部分路径未完成检查，查看具体提示" : "扫描提示（\(report.warnings.count)）"), systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Color.orange)
            }.padding(12).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            if hasAccessWarnings(report) {
                HStack(alignment: .top, spacing: 12) {
                    Text("部分路径被 macOS 拒绝访问；已完成检查的可处理项目仍可选择。")
                        .font(.caption).foregroundStyle(secondaryText)
                    Spacer(minLength: 8)
                    Button("访问权限引导…") { showingAccessGuide = true }.font(.caption)
                }
            }
        }
    }
    private func hasAccessWarnings(_ report: ScanReport) -> Bool {
        report.warnings.contains { warning in
            let text = warning.lowercased()
            if text.range(of: #"(?:errno\s*[=:]?\s*|nsposixerrordomain\s+code=)(?:1|13)(?![0-9])"#, options: .regularExpression) != nil { return true }
            return ["permission denied", "operation not permitted", "nscocoaerrordomain code=257", "您没有查看", "没有访问权限", "权限不足", "不允许该操作", "无权访问", "拒绝访问"].contains { text.contains($0) }
        }
    }
    private func resultToolbar(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(state.reportItemCount) 项").font(.headline)
                Text(Format.bytes(state.reportTotalBytes)).font(.callout).foregroundStyle(secondaryText)
                Spacer()
                TextField("搜索名称、路径或类别", text: $state.query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Toggle("大小优先", isOn: $state.largestFirst).toggleStyle(.checkbox).font(.caption)
                Button { state.exportReport() } label: { Image(systemName: "square.and.arrow.up") }.help("导出全部 JSON 扫描结果").disabled(state.pageLoading)
            }
            Text("其中 \(state.processableItemCount) 项可逐项核对处理；选择仅限当前页。")
                .font(.caption2).foregroundStyle(secondaryText)
            if let peak = report.peakResidentBytes {
                Text("本进程RSS采样峰值 \(state.memoryText(peak))" + (report.memoryBudgetBytes.map { " / 参考阈值 " + state.memoryText($0) } ?? "") + " · 间隔采样，非内核精确最大值")
                    .font(.caption2).foregroundStyle(secondaryText)
            }
        }.disabled(state.detectionUnavailable)
    }
    private var loadingPage: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在从磁盘读取这一页…").font(.callout).foregroundStyle(secondaryText)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func pageFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle).foregroundStyle(Color.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Text("分页读取失败不代表扫描没有结果；请重新扫描后再处理。").font(.caption).foregroundStyle(secondaryText)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func results(_ kind: ScanKind) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(state.visibleItems) { item in
                    itemRow(item, showBar: kind == .spaceLens)
                        .background(Color.white.opacity(0.02))
                }
            }
        }.frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(-1)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05)))
    }
    private func itemRow(_ item: ScanItem, showBar: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("选择 \(item.name)", isOn: Binding(get: { state.selected.contains(item.id) }, set: { _ in state.toggle(item) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!item.canTrash || state.detectionUnavailable)
                .help(item.canTrash ? "选择处理" : "此项只供查看")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(item.category).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 3).background(accent.opacity(0.1), in: Capsule()).foregroundStyle(accent)
                }
                Text(item.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(secondaryText).lineLimit(1).help(item.path)
                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(secondaryText).lineLimit(2).help(item.detail) }
                if let group = item.group { Text("分组：\(group)").font(.system(size: 10)).foregroundStyle(accent.opacity(0.85)).lineLimit(1).help(group) }
                if showBar {
                    GeometryReader { geometry in
                        Capsule().fill(accent.opacity(0.7)).frame(width: max(3, geometry.size.width * fraction(item)))
                    }.frame(height: 4).padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            Text(item.bytes > 0 ? Format.bytes(item.bytes) : "—").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(secondaryText).frame(minWidth: 76, alignment: .trailing)
            Button { state.reveal(item.path) } label: { Image(systemName: "folder.badge.magnifyingglass") }.buttonStyle(.borderless).help("在 Finder 中显示")
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }
    private func fraction(_ item: ScanItem) -> CGFloat {
        let maximum = state.maximumItemBytes
        guard maximum > 0 else { return 0 }
        return CGFloat(Double(item.bytes) / Double(maximum))
    }
    private func emptyResult(_ report: ScanReport) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 37)).foregroundStyle(accent)
            Text(state.query.isEmpty ? "本次范围内没有返回项目" : "没有匹配的项目").font(.headline)
            Text(state.query.isEmpty ? "这只说明当前扫描范围和规则下没有结果；不代表全盘已清理或没有安全风险。" : "尝试其他关键词，或清空搜索条件。")
                .font(.callout).foregroundStyle(secondaryText).multilineTextAlignment(.center).frame(maxWidth: 470)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var paginationBar: some View {
        HStack(spacing: 12) {
            Text("显示 \(state.firstVisibleNumber)–\(state.lastVisibleNumber) / 筛选 \(state.filteredCount) 项 · 每页 \(state.pageSize) 项")
                .font(.caption).foregroundStyle(secondaryText)
            Spacer()
            Button("上一页") { state.previousPage() }.disabled(state.detectionUnavailable || state.pageLoading || state.pageIndex == 0)
            Text("\(state.pageIndex + 1) / \(state.pageCount)").font(.caption.monospacedDigit()).foregroundStyle(secondaryText)
            Button("下一页") { state.nextPage() }.disabled(state.detectionUnavailable || state.pageLoading || state.pageIndex + 1 >= state.pageCount)
        }
    }
    private var selectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("已选择 \(state.selectedItems.count) 项 · \(Format.bytes(state.selectedBytes))").font(.callout.weight(.medium))
                Text("选择仅限当前页；翻页、搜索或排序会清空选择，不跨页处理。")
                    .font(.caption).foregroundStyle(secondaryText)
            }
            Spacer()
            Button("取消选择") { state.clearSelection() }.disabled(state.selected.isEmpty || state.busy)
            Button { state.showTrashConfirmation = true } label: { Label("清理所选…", systemImage: "trash") }
                .buttonStyle(.borderedProminent).disabled(state.selectedItems.isEmpty || state.detectionUnavailable)
                .help("核对具体项目后移到系统废纸篓；可在清理历史中恢复。")
                .accessibilityIdentifier("scan.cleanup")
        }.padding(.top, 4)
    }
}
