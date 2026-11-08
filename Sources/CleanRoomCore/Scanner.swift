import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

public final class Scanner: @unchecked Sendable {
    public init() {}
    public func scan(_ kind: ScanKind, options: ScanOptions = .init(), progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }, isCancelled: @escaping @Sendable () -> Bool = { false }) -> ScanReport {
        guard let permit = WorkBudget.tryAcquire("文件扫描：" + kind.title) else {
            return ScanReport(kind: kind, warnings: ["另一个重操作正在进行：" + (WorkBudget.currentTaskName ?? "请稍后再试")], truncated: true, stopReason: .busy)
        }
        defer { permit.release() }
        var options = options
        if kind != .protection {
            do {
                let persisted = try IgnoreRuleStore(home: options.home).load()
                let explicit = try IgnoreRuleStore.normalize(options.excludedPaths)
                options.excludedPaths = try IgnoreRuleStore.normalize(Array(Set(persisted + explicit)))
            }
            catch { return ScanReport(kind: kind, warnings: ["忽略清单读取失败，未开始扫描：" + error.localizedDescription], truncated: true, stopReason: .configurationError) }
        }
        let work = ScanWork(kind: kind, options: options, progress: progress, cancelled: isCancelled)
        switch kind {
        case .cleanup: work.cleanup()
        case .largeFiles: work.largeFiles()
        case .duplicates: work.duplicates()
        case .similarImages: work.similarImages()
        case .applications: work.applications()
        case .leftovers: work.leftovers()
        case .startup: work.startup()
        case .spaceLens: work.spaceLens()
        case .cloud: work.cloud()
        case .protection: work.protection()
        case .aiModels: work.aiModels()
        case .mailAttachments: work.mailAttachments()
        case .downloads: work.downloads()
        }
        work.finish()
        if isCancelled() { work.warn("扫描已取消；当前结果不完整。") ; work.report.truncated = true; work.report.stopReason = .cancelled }
        return work.report
    }
}

private final class ScanWork {
    let options: ScanOptions
    let progress: @Sendable (Int, String) -> Void
    let cancelled: @Sendable () -> Bool
    let fm = FileManager.default
    var report: ScanReport
    let start = Date()
    var warned = Set<String>()
    var lastResourceCheck = Date.distantPast
    var lastProgress = Date.distantPast
    var limitReached = false
    var resultStore: ScanResultStore?
    var resultStorageFailed = false
    // Only the current size() target survives until its immediate add().
    var unsafeTreePaths = Set<String>()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    init(kind: ScanKind, options: ScanOptions, progress: @escaping @Sendable (Int, String) -> Void, cancelled: @escaping @Sendable () -> Bool) {
        self.options = options; self.progress = progress; self.cancelled = cancelled; report = ScanReport(kind: kind)
        report.memoryBudgetBytes = options.memoryBudgetBytes; report.resultLimit = options.maxResults
        report.fileLimit = options.scanToCompletion || options.maxFiles == Int.max ? nil : max(1, options.maxFiles)
        report.timeLimitSeconds = !options.scanToCompletion && options.maxSeconds.isFinite ? max(0, options.maxSeconds) : nil
    }
    var home: URL { options.home }
    func h(_ suffix: String) -> URL { home.appendingPathComponent(suffix) }
    func warn(_ text: String) {
        if report.warnings.count < 80 && warned.insert(text).inserted { report.warnings.append(text) }
    }
    func stopped(countLimit: Bool = true) -> Bool {
        if cancelled() {
            report.truncated = true; report.stopReason = .cancelled
            warn("扫描已取消；当前结果不完整。"); return true
        }
        if limitReached { return true }
        let now = Date()
        if now.timeIntervalSince(lastResourceCheck) >= 0.2 {
            lastResourceCheck = now
            if let resident = ProcessResources.residentBytes() {
                report.peakResidentBytes = max(report.peakResidentBytes ?? 0, resident)
                if resident > options.memoryBudgetBytes && !options.scanToCompletion {
                    limitReached = true; report.truncated = true
                    report.stopReason = .memoryLimit
                    warn("已达到进程内存预算，扫描停止并保留已有结果；可缩小范围后重试。")
                    return true
                }
            }
        }
        if !options.scanToCompletion && countLimit && report.visitedFiles >= max(1, options.maxFiles) {
            report.truncated = true
            if report.stopReason == nil { report.stopReason = .fileLimit }
            warn("已达到本次 \(max(1, options.maxFiles)) 项文件数量上限；已访问 \(report.visitedFiles) 项。可开启完整扫描取消数量与时长限制。")
            return true
        }
        if !options.scanToCompletion && options.maxSeconds.isFinite && now.timeIntervalSince(start) >= options.maxSeconds {
            report.truncated = true
            if report.stopReason == nil { report.stopReason = .timeLimit }
            warn("已达到本次 \(Int(min(Double(Int.max / 2), max(0, options.maxSeconds)))) 秒扫描时长上限；已访问 \(report.visitedFiles) 项。可开启完整扫描取消数量与时长限制。")
            return true
        }
        return false
    }
    func step(_ path: String) {
        report.visitedFiles += 1
        if report.visitedFiles % 64 == 0, Date().timeIntervalSince(lastProgress) >= 0.2 {
            lastProgress = Date(); progress(report.visitedFiles, path)
        }
    }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    func excluded(_ url: URL) -> Bool { !options.excludedPaths.isEmpty && IgnoreRuleStore.isExcluded(url.path, by: options.excludedPaths) }
    func containsExcludedDescendant(_ url: URL) -> Bool {
        guard !options.excludedPaths.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        return options.excludedPaths.contains { $0 != path && FileSafety.contains(path, $0) }
    }
    func children(_ root: URL, _ body: (URL) -> Void) {
        guard !excluded(root), exists(root), !stopped() else { return }
        guard !FileSafety.hasSymlinkComponent(root) else { warn("跳过符号链接路径：\(root.path)"); return }
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { [self] url, error in
            report.truncated = true; warn("无法读取 \(url.path)：\(error.localizedDescription)"); return !stopped()
        }) else { report.truncated = true; warn("无法枚举：" + root.path); return }
        while !stopped() {
            let more = autoreleasepool {
                guard let url = iterator.nextObject() as? URL else { return false }
                iterator.skipDescendants()
                if !excluded(url) { body(url) }
                return true
            }
            if !more { break }
        }
    }
    func metadata(_ u: URL) -> URLResourceValues? {
        do { return try u.resourceValues(forKeys: Set(keys)) }
        catch { report.truncated = true; warn("无法读取文件属性：\(u.path)：\(error.localizedDescription)"); return nil }
    }
    func isPlaceholder(_ v: URLResourceValues) -> Bool {
        v.isUbiquitousItem == true && v.ubiquitousItemDownloadingStatus != .current && v.ubiquitousItemDownloadingStatus != .downloaded
    }
    func walk(_ roots: [URL], _ body: (URL, URLResourceValues, URL) -> Void) {
        // Deduplicate only the small root list. Individual visited paths and
        // candidate inode identities belong in the on-disk indices.
        let normalized = roots.map(\.standardizedFileURL).sorted { $0.path < $1.path }
        var disjoint: [URL] = []
        for root in normalized where !disjoint.contains(where: { FileSafety.contains($0.path, root.path) }) { disjoint.append(root) }
        for root in disjoint {
            if stopped() { break }
            if excluded(root) { continue }
            guard exists(root) else { warn("扫描根目录不存在或不可访问：\(root.path)"); continue }
            guard !FileSafety.hasSymlinkComponent(root) else { warn("跳过含符号链接的扫描根目录：\(root.path)"); continue }
            let cleanRoot = root.standardizedFileURL
            guard let en = fm.enumerator(at: cleanRoot, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { [self] u, error in
                report.truncated = true; warn("无法扫描 \(u.path)：\(error.localizedDescription)"); return !stopped()
            }) else { warn("无法扫描：\(root.path)"); continue }
            while !stopped() {
                // DirectoryEnumerator and NSURL resource lookup create autoreleased
                // Objective-C objects. Drain each iteration, not at the end of a
                // potentially hundred-thousand-file background task.
                let hasNext: Bool = autoreleasepool {
                    guard let u = en.nextObject() as? URL else { return false }
                    if excluded(u) { en.skipDescendants(); return true }
                    step(u.path)
                    guard let v = metadata(u) else { return true }
                    if v.isSymbolicLink == true { en.skipDescendants(); return true }
                    if [".Trash", ".git", ".DocumentRevisions-V100", ".Spotlight-V100", ".fseventsd"].contains(u.lastPathComponent) { en.skipDescendants(); return true }
                    if isPlaceholder(v) || FileSafety.isDataless(u) { en.skipDescendants(); warn("已跳过未下载的云占位文件；不会主动下载。"); return true }
                    body(u, v, cleanRoot)
                    return true
                }
                if !hasNext { break }
            }
        }
    }
    func size(_ root: URL) -> Int64 {
        guard !excluded(root) else { return 0 }
        let summary = MetadataTreeWalker.summarize(root: root, excludedPaths: options.excludedPaths,
                                                  shouldStop: { self.stopped() }, onVisit: { self.step($0) })
        summary.warnings.forEach { warn($0) }
        if !summary.complete { report.truncated = true; warn("目录统计未完成，不能整体清理：\(root.path)") }
        if !summary.complete || summary.unsafeToTrash { unsafeTreePaths.insert(root.standardizedFileURL.path) }
        return summary.logicalBytes
    }
    func add(_ u: URL, category: String, bytes: Int64, detail: String = "", group: String? = nil, canTrash: Bool = false, root: URL? = nil, identity: FileIdentity? = nil, retainedPath: String? = nil, retainedIdentity: FileIdentity? = nil) {
        guard !excluded(u) else { return }
        let protectsDescendant = containsExcludedDescendant(u)
        let unsafeTree = unsafeTreePaths.remove(u.standardizedFileURL.path) != nil
        // A partial directory never becomes selectable. A different completed
        // directory is not disabled merely because an earlier path was unreadable.
        let validTrash = canTrash && !protectsDescendant && !unsafeTree && !FileSafety.hasSymlinkComponent(u) && !FileSafety.isProtected(u, home: home) && root != nil
        let detail = detail + (protectsDescendant ? " 包含忽略项目，不能整体清理。" : "") + (unsafeTree ? " 含未检查或跳过的内容，不能整体清理。" : "")
        persist(ScanItem(path: u.path, category: category, bytes: bytes, detail: detail, group: group, canTrash: validTrash, identity: identity ?? FileSafety.identity(u), scopeRoot: root?.standardizedFileURL.path, retainedPath: retainedPath, retainedIdentity: retainedIdentity))
    }
    func storageFailure(_ error: Error) {
        resultStorageFailed = true; limitReached = true; report.truncated = true
        report.stopReason = .storageError
        warn("结果索引无法写入磁盘，已停止并保留已提交部分：" + error.localizedDescription)
    }
    func persist(_ item: ScanItem) {
        guard !resultStorageFailed else { return }
        do {
            if resultStore == nil { resultStore = try ScanResultStore.createTemporary() }
            try resultStore?.append(item)
        } catch { storageFailure(error) }
    }
    func finish() {
        defer { report.finishedAt = Date() }
        guard let store = resultStore else { return }
        do {
            try store.flush()
            let page = try store.page(limit: min(200, options.maxResults))
            report.items = page.items
            report.resultStore = store.reference
            report.totalItemCount = page.statistics.totalCount
            report.processableItemCount = page.statistics.processableCount
            report.allItemsBytes = page.statistics.totalBytes
        } catch {
            // Never expose a missing/corrupt reference as a complete result.
            storageFailure(error)
            let reference = store.reference; resultStore = nil
            try? ScanResultStore.remove(reference)
        }
    }
    func rootChildren(_ root: URL, category: String, canTrash: Bool = true) {
        guard !excluded(root), exists(root), !FileSafety.hasSymlinkComponent(root) else { return }
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { [self] url, error in
            report.truncated = true; warn("无法读取 \(url.path)：\(error.localizedDescription)"); return !stopped()
        }) else { return }
        while !stopped() {
            let hasNext: Bool = autoreleasepool {
                guard let u = entries.nextObject() as? URL else { return false }
                // This is a one-level listing. Recurse only in size(), which has
                // its own bounded lifetime; never materialize all children first.
                entries.skipDescendants()
                guard !excluded(u) else { return true }
                guard !FileSafety.isSymbolicLink(u), let v = metadata(u), !isPlaceholder(v), !FileSafety.isDataless(u) else { return true }
                step(u.path)
                // A regular file was fully examined above; do not spend a second
                // traversal budget check or open every ancestor again to size it.
                let bytes = v.isRegularFile == true ? Int64(v.fileSize ?? 0) : size(u)
                add(u, category: category, bytes: bytes, canTrash: canTrash, root: root)
                return true
            }
            if !hasNext { break }
        }
    }
    func defaultFileRoots() -> [URL] { options.roots.isEmpty ? [h("Downloads"), h("Documents"), h("Desktop")] : options.roots }
    func cleanup() {
        if !options.roots.isEmpty {
            for r in options.roots { rootChildren(r, category: "自选目录（请人工核对用途）") }
            return
        }
        for (p,c) in [("Library/Caches","用户缓存"),("Library/Logs","用户日志"),("Library/Developer/Xcode/DerivedData","Xcode 构建缓存")] {
            rootChildren(h(p), category:c)
        }
        warn("缓存可能包含应用离线内容；清理前请关闭相关应用并核对路径。未扫描系统缓存、废纸篓清空、文档版本或系统保护目录。")
    }
    func largeFiles() {
        let cutoff = Date().addingTimeInterval(-365 * 86400)
        walk(defaultFileRoots()) { u,v,root in
            guard v.isRegularFile == true else { return }
            let bytes = Int64(v.fileSize ?? 0)
            let old = (v.contentModificationDate ?? Date()) < cutoff
            if bytes >= options.largeFileBytes || old {
                add(u, category: bytes >= options.largeFileBytes ? "大文件" : "旧文件", bytes: bytes, detail: old ? "一年未修改；修改时间不等于最近使用时间" : "达到大小阈值", canTrash: true, root: root)
            }
        }
    }
    func hash(_ u: URL) -> (String, FileIdentity)? {
        guard !FileSafety.hasSymlinkComponent(u), let initial = FileSafety.identity(u) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: u); defer { try? handle.close() }
            var digest = SHA256()
            while true {
                if stopped(countLimit: false) { return nil }
                let count = try autoreleasepool { () throws -> Int in
                    guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return 0 }
                    digest.update(data: data)
                    return data.count
                }
                if count == 0 { break }
                if Date().timeIntervalSince(lastProgress) >= 0.2 {
                    lastProgress = Date(); progress(report.visitedFiles, u.path)
                }
            }
            guard initial == FileSafety.identity(u) else { report.truncated = true; warn("文件扫描期间发生变化，已跳过：\(u.path)"); return nil }
            return (digest.finalize().map { String(format:"%02x", $0) }.joined(), initial)
        } catch { report.truncated = true; warn("无法校验：\(u.path)：\(error.localizedDescription)"); return nil }
    }
    func duplicates() {
        do {
            let index = try ScanCandidateIndex.createTemporary()
            defer { try? index.dispose() }
            walk(defaultFileRoots()) { u, values, root in
                guard values.isRegularFile == true, let identity = FileSafety.identity(u) else { return }
                do { try index.append(path: u.path, rootPath: root.path, identity: identity, bytes: Int64(values.fileSize ?? 0)) }
                catch { storageFailure(error) }
            }
            try index.flush()
            try index.forEachDuplicateSizeCandidate(shouldStop: { self.stopped(countLimit: false) }) { candidate in
                if stopped(countLimit: false) { throw CancellationError() }
                try autoreleasepool {
                    let url = URL(fileURLWithPath: candidate.path)
                    guard let (digest, identity) = hash(url), identity == candidate.identity else { return }
                    try index.recordDigest(path: candidate.path, digest: digest, identity: identity)
                }
            }
            try index.flush()
            try index.forEachDuplicateGroupItem(shouldStop: { self.stopped(countLimit: false) }) { item in
                if stopped(countLimit: false) { throw CancellationError() }
                autoreleasepool {
                    add(URL(fileURLWithPath: item.path), category: item.isKeeper ? "保留原件" : "重复副本", bytes: item.bytes,
                        detail: item.isKeeper ? "该组保留项，不可清理" : "SHA-256 完全一致", group: item.groupDigest,
                        canTrash: !item.isKeeper, root: URL(fileURLWithPath: item.rootPath), identity: item.identity,
                        retainedPath: item.keeperPath, retainedIdentity: item.keeperIdentity)
                }
            }
        } catch is CancellationError { /* stopped() already records the reason. */ }
        catch ScanStoreError.cancelled { _ = stopped(countLimit: false) }
        catch { storageFailure(error) }
        warn("重复组每组固定保留一份；硬链接不重复计数。文件总量包含保留项，不等于可释放空间。")
    }
    func dHash(_ u: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:64,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating:0,count:72)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let context = CGContext(data:buf.baseAddress,width:9,height:8,bitsPerComponent:8,bytesPerRow:9,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(img,in:CGRect(x:0,y:0,width:9,height:8)); return true
        }
        guard drawn else { return nil }
        var result: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { if pixels[y*9+x] > pixels[y*9+x+1] { result |= UInt64(1) << (y*8+x) } } }
        return result
    }
    func similarImages() {
        do {
            let index = try ScanSimilarityIndex.createTemporary()
            defer { try? index.dispose() }
            walk(defaultFileRoots()) { u, values, root in
                guard values.isRegularFile == true, ["jpg","jpeg","png","heic","tif","tiff","webp","bmp"].contains(u.pathExtension.lowercased()),
                      let identity = FileSafety.identity(u) else { return }
                guard let hash = dHash(u) else { warn("无法解码图片，已跳过：" + u.path); return }
                guard identity == FileSafety.identity(u) else { warn("图片扫描期间发生变化，已跳过：" + u.path); return }
                do { try index.append(ScanSimilarCandidate(path: u.path, rootPath: root.path, bytes: Int64(values.fileSize ?? 0), identity: identity, hash: hash)) }
                catch { storageFailure(error) }
            }
            try index.flush()
            _ = try index.forEachGroupItem(shouldStop: { self.stopped(countLimit: false) }) { reference, item, isReference in
                autoreleasepool {
                    add(URL(fileURLWithPath: item.path), category: isReference ? "保留参考图" : "视觉近似候选", bytes: item.bytes,
                        detail: "dHash 距离 \((reference.hash ^ item.hash).nonzeroBitCount)；请预览确认", group: "similar:" + reference.path,
                        canTrash: !isReference, root: URL(fileURLWithPath: item.rootPath), identity: item.identity,
                        retainedPath: reference.path, retainedIdentity: reference.identity)
                }
            }
        } catch { storageFailure(error) }
        warn("相似图片是视觉近似候选，可能误报；不会自动选择。扫描不读取照片图库数据库。")
    }
    func appEntries() -> [(URL,[String:Any])] {
        var out: [(URL,[String:Any])] = []
        let roots = options.roots.isEmpty ? [URL(fileURLWithPath:"/Applications"), h("Applications")] : options.roots
        for root in roots {
            if excluded(root) { continue }
            if root.pathExtension == "app" {
                if let p = plist(root.appendingPathComponent("Contents/Info.plist")) { out.append((root,p)) }; continue
            }
            walk([root]) { u,v,_ in
                if u.pathExtension == "app", v.isDirectory == true, let p = plist(u.appendingPathComponent("Contents/Info.plist")) { out.append((u,p)) }
            }
        }
        return out
    }
    func plist(_ u: URL) -> [String:Any]? {
        guard let data = try? Data(contentsOf:u), let p = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { return nil }; return p
    }
    func applications() {
        for (app,p) in appEntries() {
            if stopped() { break }
            let bundle = p["CFBundleIdentifier"] as? String ?? "未知 ID"
            let version = p["CFBundleShortVersionString"] as? String ?? "未知版本"
            add(app,category:"应用程序",bytes:size(app),detail:"\(version) · \(bundle)",group:bundle,canTrash: !bundle.hasPrefix("com.apple.") && !bundle.hasPrefix("local.cleanroom") && !bundle.hasPrefix("local.aiyou.AIYOUClean"),root:app.deletingLastPathComponent())
            guard bundle != "未知 ID", !bundle.hasPrefix("com.apple.") else { continue }
            for relative in ["Library/Preferences/\(bundle).plist","Library/Caches/\(bundle)","Library/Application Support/\(bundle)","Library/Saved Application State/\(bundle).savedState","Library/HTTPStorages/\(bundle)"] {
                let u = h(relative)
                if exists(u) { add(u,category:"精确 ID 支持文件",bytes:size(u),detail:bundle,group:bundle,canTrash:true,root:u.deletingLastPathComponent()) }
            }
        }
        warn("卸载仅列出精确 bundle ID 匹配文件；不能保证发现所有残留，不扫描沙盒容器或共享支持目录。运行中的应用会拒绝移到废纸篓。")
    }
    func leftovers() {
        if [URL(fileURLWithPath: "/Applications"), h("Applications")].contains(where: { excluded($0) || containsExcludedDescendant($0) }) {
            report.truncated = true; warn("应用清单涉及忽略项目，停止残留推断，以免把已安装应用的数据当作残留。"); return
        }
        let inventory = ScanWork(kind:.applications,options:ScanOptions(home:home,maxFiles:options.maxFiles,maxSeconds:options.maxSeconds,scanToCompletion:options.scanToCompletion),progress:progress,cancelled:cancelled)
        let entries = inventory.appEntries()
        inventory.report.warnings.forEach { warn($0) }
        if inventory.report.truncated { warn("应用清单不完整，停止残留推断。"); report.truncated = true; return }
        let ids = Set(entries.compactMap { $0.1["CFBundleIdentifier"] as? String })
        let residueRoots = options.roots.isEmpty ? [h("Library/Caches"), h("Library/Preferences")] : options.roots
        for root in residueRoots {
            children(root) { u in
                step(u.path)
                let bundle = u.lastPathComponent.hasSuffix(".plist") ? u.deletingPathExtension().lastPathComponent : u.lastPathComponent
                guard bundle.contains("."), !bundle.hasPrefix("com.apple."), !ids.contains(bundle) else { return }
                add(u,category:"可能的应用残留",bytes:size(u),detail:"未在 /Applications 与 ~/Applications 找到相同 bundle ID；应用可能在其他目录，需核对",canTrash:true,root:root)
            }
        }
        warn("残留只按 bundle ID 推断，不能证明所属应用已删除；未默认选择任何项目。")
    }
    func startup() {
        let roots = options.roots.isEmpty ? [h("Library/LaunchAgents"),URL(fileURLWithPath:"/Library/LaunchAgents"),URL(fileURLWithPath:"/Library/LaunchDaemons")] : options.roots
        for root in roots {
            children(root) { u in
                guard u.pathExtension == "plist" else { return }
                step(u.path)
                guard let p = plist(u) else { warn("损坏或无法读取的启动配置：\(u.path)"); return }
                let args = p["ProgramArguments"] as? [String] ?? []
                let program = p["Program"] as? String ?? args.first ?? "未声明"
                add(u,category:root.path.contains("LaunchDaemons") ? "后台守护进程" : "登录代理",bytes:0,detail:"\(p["Label"] as? String ?? u.lastPathComponent) · \(program)",canTrash:false)
            }
        }
        warn("只列出 LaunchAgent/Daemon 配置文件，不代表服务正在运行；SMAppService 登录项需在系统设置查看。此工具不自动禁用启动项目。")
    }
    func spaceLens() {
        for root in options.roots.isEmpty ? [home] : options.roots { rootChildren(root,category:"空间分布",canTrash:false) }
        warn("大小为可读文件的逻辑大小之和；APFS 克隆、硬链接和压缩可能造成与磁盘实际占用不一致。权限失败会使统计偏小。")
    }
    func cloud() {
        let roots = options.roots.isEmpty ? [h("Library/CloudStorage"),h("Library/Mobile Documents/com~apple~CloudDocs")] : options.roots
        for root in roots { rootChildren(root,category:"已同步本地云文件",canTrash:false) }
        warn("只统计本地已下载部分，不等于云端总空间；不会连接账号、删除云端文件或触发下载。")
    }
    func aiModels() {
        let roots = options.roots.isEmpty ? [h(".ollama/models"),h(".cache/huggingface/hub"),h(".lmstudio/models"),h(".cache/lm-studio/models")] : options.roots
        for r in roots { rootChildren(r,category:"AI 模型与缓存",canTrash:false) }
        warn("模型权重与索引可能互相引用；仅展示占用，请通过对应模型工具管理，不直接删除底层 blob。")
    }
    func mailAttachments() {
        let roots = options.roots.isEmpty ? [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),h("Library/Mail Downloads")] : options.roots
        for r in roots { rootChildren(r,category:"邮件下载附件") }
        warn("仅检查已下载的 Mail 附件，不清空邮件、不连接 Gmail/Outlook。授权不足时结果可能为空。")
    }
    func downloads() {
        for r in options.roots.isEmpty ? [h("Downloads")] : options.roots { rootChildren(r,category:"下载文件") }
    }
    func protection() {
        for (name,bin,args) in [("Gatekeeper","/usr/sbin/spctl",["--status"]),("系统完整性保护 SIP","/usr/bin/csrutil",["status"]),("磁盘加密 FileVault","/usr/bin/fdesetup",["status"]),("应用防火墙","/usr/libexec/ApplicationFirewall/socketfilterfw",["--getglobalstate"])] {
            if stopped() { break }
            let result = CommandRunner.run(bin,args,timeout:8)
            persist(ScanItem(path:bin,name:name,category:"安全配置",detail:result.output.trimmingCharacters(in:.whitespacesAndNewlines),canTrash:false))
            if result.code != 0 { warn("\(name)状态获取失败（退出码 \(result.code)）。") }
        }
        warn("此页只检查系统安全配置。文件恶意软件检测请使用ClamAV检测页，并确认引擎和病毒库可用。")
    }
}
