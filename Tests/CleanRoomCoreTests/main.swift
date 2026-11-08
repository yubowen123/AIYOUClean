import Foundation

// Standalone behavioral checks: this machine's Command Line Tools do not bundle XCTest.
var failures: [String] = []
func checkTrue(_ value:@autoclosure () -> Bool, file:StaticString = #filePath, line:UInt = #line) {
    if !value() { failures.append("\(file):\(line): expected true") }
}
func checkFalse(_ value:@autoclosure () -> Bool, file:StaticString = #filePath, line:UInt = #line) { if value() { failures.append("\(file):\(line): expected false") } }
func checkEqual<T: Equatable>(_ a:T, _ b:T, file:StaticString = #filePath, line:UInt = #line) { if a != b { failures.append("\(file):\(line): values differ: \(a) != \(b)") } }
func checkLessThan<T: Comparable>(_ a:T, _ b:T, file:StaticString = #filePath, line:UInt = #line) { if !(a < b) { failures.append("\(file):\(line): expected \(a) < \(b)") } }
func checkThrows<T>(_ body:@autoclosure () throws -> T, file:StaticString = #filePath, line:UInt = #line) { do { _ = try body(); failures.append("\(file):\(line): expected error") } catch {} }
enum CheckError: Error { case missingValue }
func unwrap<T>(_ value:T?) throws -> T { guard let value else { throw CheckError.missingValue }; return value }

let checks: [(String,(CoreTests) throws -> Void)] = [
    ("duplicate hash + preserve one", { try $0.testDuplicateHashAndKeepOne() }),
    ("changed keeper blocks removal", { try $0.testChangedDuplicateKeeperRejectsRemoval() }),
    ("hardlinks not duplicate savings", { try $0.testHardLinksNotReclaimableDuplicates() }),
    ("trash + restore exact content", { try $0.testTrashAndRestoreExactContent() }),
    ("restore never overwrites", { try $0.testRestoreRefusesOverwrite() }),
    ("changed file blocks removal", { try $0.testChangedFileRejected() }),
    ("symlinks not traversed", { try $0.testSymlinkNotTraversed() }),
    ("parent symlink swap rejected", { try $0.testReplacingParentWithSymlinkRejected() }),
    ("protected home rejected", { $0.testProtectedHomeRejected() }),
    ("scope boundary by path component", { try $0.testRootBoundaryUsesComponentNotStringPrefix() }),
    ("overlapping selections rejected", { try $0.testOverlappingSelectionsRejected() }),
    ("limits + cancellation visible", { try $0.testTruncationAndCancellationReported() }),
    ("directory sizes read only", { try $0.testSpaceStatsAndNoDeletion() }),
    ("app support exact ID match", { try $0.testApplicationsPreciseSupportFiles() }),
    ("nested framework sizes included", { try $0.testApplicationSizeIncludesNestedFramework() }),
    ("invalid startup plist visible", { try $0.testMalformedStartupPlistProducesWarning() }),
    ("process timeout", { $0.testCommandTimeout() }),
    ("JSON evidence round trip", { try $0.testJSONRoundTripIncludesLimits() }),
    ("image similarity candidates", { try $0.testSimilarImageCandidates() }),
    ("restore rejects replaced parent directory", { try $0.testRestoreRejectsReplacedParentDirectory() }),
    ("restore rejects changed trash item", { try $0.testRestoreRejectsChangedTrashItem() }),
    ("macOS Trash + restore integration (generated fixture)", { try $0.testMacOSTrashAndRestoreIntegration() })
]
var passed = 0
for (name,body) in checks {
    let suite = CoreTests(); let before = failures.count
    do { try suite.setUpWithError(); try body(suite) } catch { failures.append("\(name): \(error)") }
    do { try suite.tearDownWithError() } catch { failures.append("fixture cleanup: \(error)") }
    if before == failures.count { print("PASS \(name)"); passed += 1 } else { print("FAIL \(name)") }
}
let extraChecks: [(String, () throws -> Void)] = [
    ("resource limits + work budget", runResourceChecks),
    ("ClamAV scan + quarantine fixtures", runMalwareChecks),
    ("OAuth + paged provider mocks", runConnectedChecks),
    ("appcast + update safety mocks", runUpdateChecks),
    ("extended cleanup + versions fixtures", runExtendedChecks),
    ("browser privacy SQLite fixtures", runPrivacyChecks),
    ("product entry policy", runProductFeatureChecks),
    ("ignore rules scan + cleanup integration", runIgnoreIntegrationChecks),
    ("history cursor pagination", runHistoryPaginationChecks),
    ("smart care + ignore store fixtures", runSmartCareChecks),
    ("SmartCare merge protection + cancellation + cached-store semantics", runSmartMergeChecks),
    ("partial cleanup result retention + atomic metadata prune", runResultRetentionChecks),
    ("interactive space analysis fixtures", runSpaceLensChecks),
    ("explicit scan completion + stop reasons", runScanCompletionChecks),
    ("streaming metadata tree + boundaries", runMetadataTreeChecks),
    ("disk result + candidate indices", runScanStoreChecks),
    ("streaming self-contained report export", runExportChecks),
    ("disk image similarity index", runSimilarIndexChecks),
    ("real continuous SmartCare beyond 50000 entries", runContinuousScanChecks),
    ("full disk scope and mount policy", runFullDiskScopeChecks),
    ("full disk file inventory and cross-root duplicates", runFullDiskFileChecks),
    ("whole scope SmartCare and literal private paths", runFullDiskSmartCareChecks)
]
for (name, body) in extraChecks {
    let before = failures.count
    do { try body() } catch { failures.append("\(name): \(error)") }
    if before == failures.count { print("PASS \(name)"); passed += 1 } else { print("FAIL \(name)") }
}
print("\(passed)/\(checks.count + extraChecks.count) checks/groups passed")
for failure in failures { print(failure) }
if !failures.isEmpty { exit(1) }
