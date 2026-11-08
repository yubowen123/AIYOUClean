import Foundation
import Darwin
import CleanRoomCore

private struct MergeOwnedStoreEnvelope: Decodable {
    let kind: String
    let childPID: Int32
    let references: [ScanResultReference]
}
private enum MergeOwnedStoreCleanup {
    static func run(_ path: String) -> Int32 {
        var result: [String: Any] = ["passed": false, "operation": "cleanup-owned-refs", "records": [[String: Any]]()]
        do {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NSError(domain: "OwnedRefsJSON", code: Int(errno)) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1,
                  metadata.st_size <= 1_048_576 else { throw NSError(domain: "OwnedRefsJSON", code: 1) }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw NSError(domain: "OwnedRefsJSON", code: 2) }
            let references: [ScanResultReference]
            if let plain = try? JSONDecoder().decode([ScanResultReference].self, from: data) { references = plain }
            else {
                let envelope = try JSONDecoder().decode(MergeOwnedStoreEnvelope.self, from: data)
                guard envelope.kind == "AIYOUClean.SmartMergeOwnedStores", envelope.childPID > 0 else { throw NSError(domain: "OwnedRefsJSON", code: 3) }
                references = envelope.references
            }
            guard references.count <= 1024 else { throw NSError(domain: "OwnedRefsJSON", code: 4) }
            // Validate the complete explicit list before removing the first ref.
            for ref in references {
                guard let uuid = UUID(uuidString: ref.sessionID), uuid.uuidString == ref.sessionID,
                      ref.path.hasPrefix("/"), !ref.path.utf8.contains(0), ref.path.utf8.count <= 32768 else { throw NSError(domain: "OwnedRefStructure", code: 1) }
                let url = URL(fileURLWithPath: ref.path)
                guard url.lastPathComponent == "results.sqlite3",
                      url.deletingLastPathComponent().lastPathComponent == "AIYOUClean-results-" + ref.sessionID else { throw NSError(domain: "OwnedRefStructure", code: 2) }
            }
            var records: [[String: Any]] = []
            var failed = false
            var seen = Set<String>()
            for ref in references where seen.insert(ref.path).inserted {
                var entry: [String: Any] = ["path": ref.path, "sessionID": ref.sessionID]
                var directory = stat()
                let parent = URL(fileURLWithPath: ref.path).deletingLastPathComponent().path
                if lstat(parent, &directory) != 0 && errno == ENOENT { entry["status"] = "alreadyRemoved" }
                else {
                    do {
                        // This API alone validates canonical temp location,
                        // UUID/schema, ownership and no-follow storage bounds.
                        try ScanResultStore.remove(ref)
                        entry["status"] = "removedOrAlreadyGone"
                    } catch {
                        failed = true; entry["status"] = "refused"; entry["error"] = error.localizedDescription
                    }
                }
                records.append(entry)
            }
            result["records"] = records; result["passed"] = !failed
        } catch { result["error"] = error.localizedDescription }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        return result["passed"] as? Bool == true ? 0 : 1
    }
}

#if MERGE_CLEANUP_ONLY
@main struct SmartMergeCleanupTool {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cleanup-owned-refs" else { exit(2) }
        exit(MergeOwnedStoreCleanup.run(CommandLine.arguments[2]))
    }
}
#else
private final class MergeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var first: Double?
    func record(_ value: SmartCareProgress) {
        let phase = Mirror(reflecting: value).children.first { $0.label == "phase" }.map { String(describing: $0.value) } ?? ""
        if [phase, value.path].contains(where: { $0.contains("合并") || $0.contains("汇总") }) {
            var announce = false
            lock.lock(); events += 1
            if first == nil { first = ProcessInfo.processInfo.systemUptime; announce = true }
            lock.unlock()
            if announce {
                print("CHECKPOINT first-merge-progress visited=\(value.visitedFiles) phase=\(phase) path=\(value.path)")
                fflush(stdout)
            }
        }
    }
    var snapshot: (Int, Double?) { lock.lock(); defer { lock.unlock() }; return (events, first) }
}
private struct MergeScaleProvider: SmartCareScanProviding {
    let reference: ScanResultReference
    let count: Int
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        if kind == .cleanup {
            var result = ScanReport(kind: kind, visitedFiles: count)
            result.resultStore = reference; result.totalItemCount = count
            return result
        }
        return ScanReport(kind: kind)
    }
}
@main struct SmartMergeScaleChecks {
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--cleanup-owned-refs" {
            exit(MergeOwnedStoreCleanup.run(CommandLine.arguments[2]))
        }
        guard (4...5).contains(CommandLine.arguments.count), let count = Int(CommandLine.arguments[3]), (1...1_000_000).contains(count) else { exit(2) }
        let detailRepeat = CommandLine.arguments.count == 5 ? Int(CommandLine.arguments[4]) ?? -1 : 114
        guard (0...4096).contains(detailRepeat) else { exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        var evidence: [String: Any] = ["passed": false, "pid": getpid(), "rows": count, "detailRepeat": detailRepeat, "realFilesCreated": 0]
        var owned: [ScanResultReference] = []
        defer { for reference in owned { try? ScanResultStore.remove(reference) } }
        do {
            guard root.deletingLastPathComponent().lastPathComponent == ".test-fixtures", root.lastPathComponent.hasPrefix("smart-merge-"), !FileSafety.hasSymlinkComponent(root) else { throw NSError(domain: "OwnedFixture", code: 1) }
            evidence["coreTemporaryDirectory"] = FileManager.default.temporaryDirectory.path
            print("CHECKPOINT generation-start rows=\(count) temporary-directory=\(FileManager.default.temporaryDirectory.path)")
            fflush(stdout)
            let home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let generationStart = ProcessInfo.processInfo.systemUptime
            let reference: ScanResultReference = try autoreleasepool {
                let store = try ScanResultStore.createTemporary()
                owned.append(store.reference)
                let detail = String(repeating: "generated-metadata ", count: detailRepeat)
                for number in 0..<count {
                    try autoreleasepool {
                        let path = home.appendingPathComponent("Library/Caches/generated/group-\(number / 1000)/entry-\(number)").path
                        try store.append(ScanItem(path: path, category: "generated merge input", bytes: 64, detail: detail, canTrash: true, scopeRoot: home.path))
                    }
                }
                try store.flush()
                return store.reference
            }
            evidence["generationSeconds"] = ProcessInfo.processInfo.systemUptime - generationStart
            evidence["inputDatabaseBytes"] = try FileManager.default.attributesOfItem(atPath: reference.path)[.size]
            print("CHECKPOINT generation-finished rows=\(count) seconds=\(evidence["generationSeconds"] ?? 0) database-bytes=\(evidence["inputDatabaseBytes"] ?? 0)")
            fflush(stdout)
            let events = MergeEventRecorder(), start = ProcessInfo.processInfo.systemUptime
            let report = SmartCareService(provider: MergeScaleProvider(reference: reference, count: count)).scan(options: SmartCareOptions(home: home, scanScope: .localMaintenance), progress: { events.record($0) })
            evidence["mergeSeconds"] = ProcessInfo.processInfo.systemUptime - start
            for reference in [report.resultStore, report.readOnlyStore, report.diskCoverage?.issueStore].compactMap({ $0 }) { owned.append(reference) }
            guard let merged = report.resultStore else { throw NSError(domain: "MissingResult", code: 2) }
            let statistics = try ScanResultStore(reference: merged).statistics()
            evidence["outputRows"] = statistics.totalCount
            evidence["outputBytes"] = statistics.totalBytes
            evidence["outputDatabaseBytes"] = try FileManager.default.attributesOfItem(atPath: merged.path)[.size]
            evidence["mergeProgressEvents"] = events.snapshot.0
            evidence["firstMergeProgressSeconds"] = events.snapshot.1.map { $0 - start }
            evidence["truncated"] = report.incomplete; evidence["invalidated"] = report.invalidated
            evidence["mergeCompleted"] = statistics.totalCount == count && !report.incomplete && !report.invalidated
            evidence["progressAssertionPassed"] = events.snapshot.0 > 0
            evidence["passed"] = (evidence["mergeCompleted"] as? Bool == true) && events.snapshot.0 > 0
        } catch { evidence["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { print(error); exit(2) }
        print(String(decoding: (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
        if evidence["passed"] as? Bool != true { exit(1) }
    }
}
#endif
