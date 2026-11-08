import Foundation
import Darwin

public enum SmartCareScanScope: String, CaseIterable, Sendable, Identifiable {
    case allLocalDisks, selectedFolders, localMaintenance
    public var id: String { rawValue }
    public var title: String {
        switch self { case .allLocalDisks: return "全盘检查"; case .selectedFolders: return "自选文件夹"; case .localMaintenance: return "本地维护范围" }
    }
}

public struct SmartCareOptions: Sendable {
    public var home: URL
    public var includeApplications: Bool
    // Retained for callers that used these as batch/preview preferences. They no
    // longer impose a composite deadline, file limit or result truncation.
    public var maxFiles: Int
    public var maxSeconds: TimeInterval
    public var maxResults: Int
    public var memoryBudgetBytes: UInt64
    public var excludedPaths: [String]
    public var scanScope: SmartCareScanScope
    public var roots: [URL]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, includeApplications: Bool = false, maxFiles: Int = .max, maxSeconds: TimeInterval = .infinity, maxResults: Int = 200, memoryBudgetBytes: UInt64 = 512 * 1024 * 1024, excludedPaths: [String] = [], scanScope: SmartCareScanScope = .allLocalDisks, roots: [URL] = []) {
        self.home = home.standardizedFileURL; self.includeApplications = includeApplications
        self.maxFiles = max(1, maxFiles); self.maxSeconds = maxSeconds
        self.maxResults = max(1, maxResults); self.memoryBudgetBytes = max(64 * 1024 * 1024, memoryBudgetBytes); self.excludedPaths = excludedPaths; self.scanScope = scanScope; self.roots = roots
    }
}
public struct SmartCareProgress: Sendable {
    public let module: ScanKind
    public let visitedFiles: Int
    public let path: String
    public var phase: String? = nil
}
public struct SmartCareModuleSummary: Identifiable, Sendable {
    public var id: ScanKind { kind }
    public let kind: ScanKind
    public let count: Int
    public let processableCount: Int
    public let readOnlyCount: Int
    public let permissionRequired: Bool
    public let bytes: Int64
    public let visitedFiles: Int
    public let warnings: [String]
    public let observations: [String]
    public let incomplete: Bool
    public let skipped: Bool
}
public struct SmartCareReport: Sendable {
    public let startedAt: Date
    public var finishedAt: Date
    public var modules: [SmartCareModuleSummary] = []
    /// First 200 candidates only. All merged candidates live in resultStore.
    public var items: [ScanItem] = []
    public var resultStore: ScanResultReference?
    public var readOnlyStore: ScanResultReference?
    public var readOnlyStoredCount = 0
    public var diskCoverage: FullDiskCoverage?
    public var totalItemCount = 0
    public var totalProcessableBytes: Int64 = 0
    public var warnings: [String] = []
    public var visitedFiles = 0
    public var incomplete = false
    public var cancelled = false
    public var invalidated = false
    public var peakResidentBytes: UInt64 = 0
    public var appliedIgnoreRules: [String] = []
    public var readOnlyItemCount: Int { modules.reduce(0) { $0 + $1.readOnlyCount } }
    public var permissionRequiredModuleCount: Int { modules.filter(\.permissionRequired).count }
}
protocol SmartCareScanProviding: Sendable {
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport
}
private struct SmartCareDefaultProvider: SmartCareScanProviding {
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        if kind != .protection {
            return Scanner().scan(kind, options: options, progress: progress, isCancelled: { cancellation.isCancelled })
        }
        var report = ScanReport(kind: .protection)
        guard let permit = WorkBudget.tryAcquire("综合检查：系统安全状态") else {
            report.truncated = true; report.stopReason = .busy; report.warnings = ["另一个重型操作正在进行，未检查本模块。"]
            return report
        }
        defer { permit.release() }
        let commands: [(String, String, [String])] = [("Gatekeeper", "/usr/sbin/spctl", ["--status"]), ("SIP", "/usr/bin/csrutil", ["status"]), ("FileVault", "/usr/bin/fdesetup", ["status"]), ("应用防火墙", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])]
        for (name, path, arguments) in commands {
            if cancellation.isCancelled { report.truncated = true; report.stopReason = .cancelled; break }
            // Each external status command has its own timeout; there is no
            // composite scanning deadline and a failed command does not block others.
            let output = MalwareProcessRunner.run(URL(fileURLWithPath: path), arguments, timeout: 8, cancellation: cancellation)
            let text = String((output.stdout + output.stderr).prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
            report.items.append(ScanItem(path: path, name: name, category: "安全配置状态", detail: text.isEmpty ? (output.launchError ?? "无返回内容") : text, canTrash: false))
            if output.exitCode != 0 || output.cancelled || output.timedOut || output.outputTruncated || output.launchError != nil { report.truncated = true; report.warnings.append("\(name)状态未完整取得。") }
            progress(report.items.count, name)
        }
        report.warnings.append("这里只检查系统配置，不检测恶意文件，也不代表系统未感染。")
        report.finishedAt = Date(); report.peakResidentBytes = ProcessResources.residentBytes()
        return report
    }
}

/// Runs local modules sequentially. Candidate and keeper sets stay in SQLite;
/// scanning limits do not turn into composite limits or skip subsequent modules.
public final class SmartCareService: @unchecked Sendable {
    private let provider: any SmartCareScanProviding
    public init() { provider = SmartCareDefaultProvider() }
    init(provider: any SmartCareScanProviding) { self.provider = provider }
    public func scan(options: SmartCareOptions = SmartCareOptions(), cancellation: MalwareCancellation = MalwareCancellation(), progress: @escaping @Sendable (SmartCareProgress) -> Void = { _ in }) -> SmartCareReport {
        let start = Date()
        var result = SmartCareReport(startedAt: start, finishedAt: start)
        let ignoreStore = IgnoreRuleStore(home: options.home)
        let persisted: [String], rules: [String], explicitRules: [String]
        do {
            persisted = try ignoreStore.load(); explicitRules = try IgnoreRuleStore.normalize(options.excludedPaths)
            rules = try IgnoreRuleStore.normalize(Array(Set(persisted + explicitRules)))
        } catch {
            result.incomplete = true; result.invalidated = true; result.warnings = [error.localizedDescription]; result.finishedAt = Date()
            return result
        }
        result.appliedIgnoreRules = rules
        let plan: FullDiskScanPlan?
        switch options.scanScope {
        case .allLocalDisks: plan = FullDiskScopePlanner.localDisks(home: options.home)
        case .selectedFolders:
            let selected = FullDiskScopePlanner.selectedFolders(options.roots, home: options.home)
            guard !selected.roots.isEmpty else {
                result.incomplete = true; result.invalidated = true; result.warnings = ["请先选择要检查的文件夹，未默认扫描其他位置。"]
                return result
            }
            plan = selected
        case .localMaintenance: plan = nil
        }
        var kinds: [ScanKind] = plan == nil ? [.cleanup, .duplicates, .protection] : [.cleanup, .largeFiles, .duplicates, .protection]
        // Explicit folder mode must not expand to global installed-app locations.
        if options.includeApplications && options.scanScope != .selectedFolders { kinds.append(.applications) }
        var merged: ScanResultStore?, keepers: ScanResultStore?, readOnly: ScanResultStore?
        var keeperReference: ScanResultReference?
        var disk: FullDiskFileReport?
        defer {
            keepers = nil
            if let keeperReference { try? ScanResultStore.remove(keeperReference) }
            // Child stores remain owned even when cancellation skips their merge.
            for reference in [disk?.largeFiles.resultStore, disk?.duplicates.resultStore].compactMap({ $0 }) { try? ScanResultStore.remove(reference) }
        }
        do {
            merged = try ScanResultStore.createTemporary(deferQueryIndexes: true)
            readOnly = try ScanResultStore.createTemporary(deferQueryIndexes: true)
            keepers = try ScanResultStore.createTemporary(deferQueryIndexes: true); keeperReference = keepers?.reference
        } catch {
            for reference in [merged?.reference, readOnly?.reference].compactMap({ $0 }) { try? ScanResultStore.remove(reference) }
            result.incomplete = true; result.invalidated = true
            result.warnings = ["无法建立磁盘结果索引，未开始检查：" + error.localizedDescription]; result.finishedAt = Date()
            return result
        }
        var fatalReason: String?
        for kind in kinds {
            if cancellation.isCancelled || result.invalidated || fatalReason != nil {
                result.incomplete = true
                result.modules.append(skipped(kind, reason: cancellation.isCancelled ? "用户已取消，未执行本模块。" : (fatalReason ?? "配置已失效，未执行本模块。")))
                continue
            }
            do {
                guard try ignoreStore.load() == persisted else {
                    result.invalidated = true; result.incomplete = true
                    result.warnings.append("检查期间忽略清单已变化，旧结果已失效；请重新扫描。")
                    result.modules.append(skipped(kind, reason: "忽略清单已变化，未执行本模块。")); continue
                }
            } catch {
                result.invalidated = true; result.incomplete = true; result.warnings.append(error.localizedDescription)
                result.modules.append(skipped(kind, reason: "忽略清单读取失败，未执行本模块。")); continue
            }
            let roots: [URL]
            if let plan, kind == .cleanup { roots = plan.cleanupRoots }
            else { roots = kind == .duplicates ? [options.home.appendingPathComponent("Downloads")] : [] }
            var scanOptions = ScanOptions(home: options.home, roots: roots, maxFiles: .max, maxSeconds: .infinity, maxResults: 200, memoryBudgetBytes: options.memoryBudgetBytes)
            scanOptions.scanToCompletion = true
            scanOptions.excludedPaths = explicitRules
            let baselineCount = result.visitedFiles
            let module: ScanReport = autoreleasepool {
                if let plan, kind == .largeFiles {
                    disk = FullDiskFileScanner().scan(plan: plan, home: options.home, cancellation: cancellation, excludedPaths: explicitRules, progress: { count, path in
                        progress(SmartCareProgress(module: path.hasPrefix("SHA-256：") ? .duplicates : .largeFiles, visitedFiles: baselineCount + count, path: String(path.prefix(2048))))
                    })
                    result.diskCoverage = disk?.coverage
                    var report = disk!.largeFiles
                    report.visitedFiles = disk!.coverage.visitedEntries
                    return report
                }
                if let disk, kind == .duplicates {
                    var report = disk.duplicates; report.visitedFiles = disk.coverage.regularFiles
                    return report
                }
                if plan != nil && kind == .cleanup && roots.isEmpty {
                    return ScanReport(kind: kind, warnings: ["本次文件范围不包含已知缓存目录，未将普通文件夹识别为垃圾。"])
                }
                return provider.scan(kind, options: scanOptions, cancellation: cancellation, deadline: .infinity, progress: { count, path in
                    progress(SmartCareProgress(module: kind, visitedFiles: baselineCount + count, path: String(path.prefix(2048))))
                })
            }
            if kind != .duplicates || disk == nil { result.visitedFiles += module.visitedFiles }
            result.peakResidentBytes = max(result.peakResidentBytes, module.peakResidentBytes ?? ProcessResources.residentBytes() ?? 0)
            do {
                guard let merged, let keepers, let readOnly else { throw CocoaError(.fileWriteUnknown) }
                let visited = result.visitedFiles
                let summary = try merge(module, into: merged, keepers: keepers, readOnly: readOnly, rules: rules, home: options.home, fullScope: plan != nil, cancellation: cancellation, progress: { stage, done, total in
                    progress(SmartCareProgress(module: kind, visitedFiles: visited, path: "已汇总\(done)/\(total)项", phase: stage))
                })
                result.modules.append(summary); result.incomplete = result.incomplete || summary.incomplete
                if module.stopReason == .configurationError { result.invalidated = true }
            } catch is CancellationError {
                result.incomplete = true
                result.modules.append(skipped(kind, reason: "用户已取消，未继续合并本模块。"))
            } catch {
                let reason = "磁盘结果索引无法继续写入：" + error.localizedDescription
                fatalReason = reason; result.incomplete = true; result.invalidated = true; result.warnings.append(reason)
                result.modules.append(skipped(kind, reason: reason))
            }
            // The child report owns its temporary index until merging finishes.
            if let reference = module.resultStore { try? ScanResultStore.remove(reference) }
        }
        do {
            if try ignoreStore.load() != persisted {
                result.invalidated = true; result.incomplete = true
                result.warnings.append("忽略清单已变化，合并结果失效；请重新扫描。")
            }
            if !result.invalidated, let merged, let keepers, let readOnly {
                progress(SmartCareProgress(module: .duplicates, visitedFiles: result.visitedFiles, path: "正在整理完整结果，准备显示", phase: "整理检查结果"))
                try keepers.flush()
                try merged.flush()
                let statistics = try merged.statistics()
                result.totalItemCount = statistics.totalCount
                result.totalProcessableBytes = statistics.processableBytes
                result.resultStore = merged.reference
                try readOnly.flush()
                result.readOnlyStoredCount = try readOnly.statistics().totalCount
                result.readOnlyStore = readOnly.reference
                // Build the wide sorting indexes once, after all removals. A
                // narrow byte index keeps deletion statistics O(log n) earlier.
                if !cancellation.isCancelled {
                    progress(SmartCareProgress(module: .duplicates, visitedFiles: result.visitedFiles, path: "正在整理可处理项目", phase: "整理检查结果"))
                    try merged.prepareForPaging(isCancelled: { cancellation.isCancelled })
                    progress(SmartCareProgress(module: .duplicates, visitedFiles: result.visitedFiles, path: "正在整理只读发现", phase: "整理检查结果"))
                    try readOnly.prepareForPaging(isCancelled: { cancellation.isCancelled })
                    result.items = try merged.page(limit: 200, processableOnly: true, isCancelled: { cancellation.isCancelled }).items
                }
            }
        } catch ScanStoreError.cancelled where cancellation.isCancelled {
            // Already merged data/references stay usable; cancellation of an
            // index build must not discard the partial report as a write error.
            result.incomplete = true
        } catch {
            result.invalidated = true; result.incomplete = true; result.warnings.append("无法读取合并结果：" + error.localizedDescription)
        }
        if result.invalidated {
            let references = [merged?.reference, readOnly?.reference, result.diskCoverage?.issueStore].compactMap { $0 }
            merged = nil; readOnly = nil
            for reference in references { try? ScanResultStore.remove(reference) }
            result.items = []; result.resultStore = nil; result.readOnlyStore = nil
            result.readOnlyStoredCount = 0; result.diskCoverage?.issueStore = nil
            result.totalItemCount = 0; result.totalProcessableBytes = 0
        }
        result.cancelled = cancellation.isCancelled; result.incomplete = result.incomplete || result.cancelled
        if result.cancelled { result.warnings.append("检查已取消；已完成模块的可处理候选仍可复查，未执行后续模块或自动清理。") }
        result.finishedAt = Date()
        return result
    }
    private func merge(_ module: ScanReport, into merged: ScanResultStore, keepers: ScanResultStore, readOnly: ScanResultStore, rules: [String], home: URL, fullScope: Bool, cancellation: MalwareCancellation, progress: (String, Int, Int) -> Void) throws -> SmartCareModuleSummary {
        var count = 0, processable = 0, readOnlyCount = 0
        var bytes: Int64 = 0
        var observations: [String] = []
        let source = try module.resultStore.map { try ScanResultStore(reference: $0) }
        let sourceStatistics = try source?.statistics()
        let total = sourceStatistics?.totalCount ?? module.items.count
        let actionable = sourceStatistics?.processableCount ?? module.items.filter(\.canTrash).count
        func normalized(_ item: ScanItem) -> ScanItem {
            guard fullScope, item.canTrash, module.kind == .cleanup || module.kind == .applications else { return item }
            // A broader scan grants no deletion right to system caches or other
            // accounts. Keep them inspectable, without adding an admin workflow.
            var metadata = stat()
            let withinHome = FileSafety.contains(home.path, item.path)
            let allowedApplication = module.kind == .applications && item.path.hasPrefix("/Applications/")
            if (withinHome || allowedApplication) && lstat(item.path, &metadata) == 0 && metadata.st_uid == getuid() { return item }
            return ScanItem(path: item.path, name: item.name, category: item.category, bytes: item.bytes,
                            detail: item.detail + " 全盘检查只读：系统、其他用户或非本人拥有的项目。", group: item.group, canTrash: false,
                            identity: item.identity, scopeRoot: item.scopeRoot, retainedPath: item.retainedPath, retainedIdentity: item.retainedIdentity)
        }
        func forEach(processableOnly: Bool = false, _ body: (ScanItem) throws -> Void) throws {
            func consume(_ item: ScanItem) throws {
                if cancellation.isCancelled { throw CancellationError() }
                try body(normalized(item))
            }
            if let source {
                do { try source.forEachItem(processableOnly: processableOnly, isCancelled: { cancellation.isCancelled }, consume) }
                catch ScanStoreError.cancelled where cancellation.isCancelled { throw CancellationError() }
            }
            else { for item in module.items where !processableOnly || item.canTrash { try consume(item) } }
        }
        // This pass remains bounded even when the module has millions of rows.
        let reading = "汇总" + module.kind.title + "结果"
        progress(reading, 0, total)
        try forEach { item in
            count += 1
            if !item.canTrash { readOnlyCount += 1; try readOnly.append(item) }
            if module.kind == .protection && observations.count < 8 { observations.append(String((item.name + "：" + item.detail).prefix(2048))) }
            if let keeper = item.retainedPath {
                if try keepers.appendIfNoOverlap(ScanItem(path: keeper, category: "智能检查保留原件")) {
                    try merged.removeAncestors(of: keeper)
                }
            }
            if count % 512 == 0 || count == total { progress(reading, count, total) }
        }
        var processed = 0
        let hasKeepers = try keepers.statistics().totalCount > 0
        let writing = "合并" + module.kind.title + "候选"
        progress(writing, 0, actionable)
        try forEach(processableOnly: true) { item in
            processed += 1
            if processed % 512 == 0 || processed == actionable { progress(writing, processed, actionable) }
            guard item.canTrash, item.retainedPath != item.path,
                  !IgnoreRuleStore.isExcluded(item.path, by: rules),
                  !rules.contains(where: { FileSafety.contains(item.path, $0) }) else { return }
            processable += 1; bytes += item.bytes
            // Earlier candidates are removed when a keeper is discovered; all
            // later candidates are checked here. No final millions-row sweep.
            if hasKeepers, try keepers.containsDescendantOrSame(item.path) { return }
            _ = try merged.appendIfNoOverlap(item)
        }
        let permissionRequired = module.warnings.contains(where: Self.requiresPermission)
        let structuredDiskReport = fullScope && (module.kind == .largeFiles || module.kind == .duplicates)
        let incomplete = module.truncated || permissionRequired || (!structuredDiskReport && module.warnings.contains { warning in
            ["无法", "失败", "跳过", "不存在", "另一个重"].contains { warning.contains($0) }
        })
        return SmartCareModuleSummary(kind: module.kind, count: count, processableCount: processable, readOnlyCount: readOnlyCount, permissionRequired: permissionRequired, bytes: bytes, visitedFiles: module.visitedFiles, warnings: Array(module.warnings.prefix(80)), observations: observations, incomplete: incomplete, skipped: count == 0 && module.truncated)
    }
    private static func requiresPermission(_ text: String) -> Bool {
        let value = text.lowercased()
        if value.range(of: #"(?:errno\s*[=:]?\s*|nsposixerrordomain\s+code=)(?:1|13)(?![0-9])"#, options: .regularExpression) != nil { return true }
        return ["operation not permitted", "permission denied", "nscocoaerrordomain code=257", "您没有查看", "没有访问权限", "权限不足", "不允许该操作"].contains { value.contains($0) }
    }
    private func skipped(_ kind: ScanKind, reason: String) -> SmartCareModuleSummary {
        SmartCareModuleSummary(kind: kind, count: 0, processableCount: 0, readOnlyCount: 0, permissionRequired: false, bytes: 0, visitedFiles: 0, warnings: [reason], observations: [], incomplete: true, skipped: true)
    }
}
