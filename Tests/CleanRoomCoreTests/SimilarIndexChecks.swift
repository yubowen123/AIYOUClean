import Foundation
@testable import CleanRoomCore

private enum SimilarIndexFixtureError: Error { case stop }
func runSimilarIndexChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/similarity-index-" + UUID().uuidString)
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    let source = fixture.appendingPathComponent("keep-generated-source")
    try Data("metadata-only indices must not read or modify this fixture".utf8).write(to: source)
    func item(_ name: String, _ hash: UInt64, _ number: Int) -> ScanSimilarCandidate {
        let bytes = Int64(10 + number % 7)
        return ScanSimilarCandidate(path: fixture.appendingPathComponent(name).path, rootPath: fixture.path, bytes: bytes, identity: FileIdentity(device: 1, inode: UInt64(number + 1), size: bytes, modified: 1), hash: hash)
    }
    // Even-parity 16-bit words differ in >=2 bits; repeating four times gives
    // pairwise Hamming distance >=8. Only the final duplicated hash can group.
    func separatedHash(_ number: Int) -> UInt64 {
        let code = UInt64((number << 1) | (number.nonzeroBitCount & 1))
        return code | (code << 16) | (code << 32) | (code << 48)
    }
    let sparse = try ScanSimilarityIndex.createTemporary(); defer { try? sparse.dispose() }
    for number in 0..<3200 {
        try autoreleasepool { try sparse.append(item(String(format: "sparse-%05d", number), separatedHash(number), number)) }
    }
    try sparse.append(item("sparse-03200", separatedHash(3199), 3200))
    var sparseCount = 0, sparseReferences = 0, sparseLast: String?
    let sparseComplete = try sparse.forEachGroupItem(shouldStop: { false }) { reference, candidate, isReference in
        sparseCount += 1; if isReference { sparseReferences += 1; checkEqual(candidate.path, reference.path) }
        checkTrue(reference.path.hasSuffix("sparse-03199")); sparseLast = candidate.path
    }
    checkTrue(sparseComplete); checkEqual(sparseCount, 2); checkEqual(sparseReferences, 1); checkTrue(sparseLast?.hasSuffix("sparse-03200") == true)
    var stopChecks = 0
    let stopped = try sparse.forEachGroupItem(shouldStop: { stopChecks += 1; return stopChecks > 12 }) { _, _, _ in }
    checkFalse(stopped)
    let immediateStop = try sparse.forEachGroupItem(shouldStop: { true }) { _, _, _ in failures.append("cancelled similarity iterator emitted an item") }
    checkFalse(immediateStop)
    var resumed = 0
    let rerun = try sparse.forEachGroupItem(maxDistance: 0, shouldStop: { false }) { _, _, _ in resumed += 1 }
    checkTrue(rerun); checkEqual(resumed, 2)
    let boundary = try ScanSimilarityIndex.createTemporary(); defer { try? boundary.dispose() }
    let five: UInt64 = (UInt64(1) << 0) | (UInt64(1) << 11) | (UInt64(1) << 22) | (UInt64(1) << 33) | (UInt64(1) << 44)
    let six: UInt64 = five | (UInt64(1) << 54)
    let boundaryItems = [item("boundary-a-zero", 0, 0), item("boundary-b-five", five, 1), item("boundary-c-six", six, 2), item("boundary-d-full", UInt64.max, 3), item("boundary-e-full-five", UInt64.max ^ five, 4), item("boundary-f-isolated", 0xaaaaaaaaaaaaaaaa, 5)]
    for candidate in boundaryItems.reversed() { try boundary.append(candidate) }
    var boundaryCount = 0, referenceCount = 0, currentReference = "", seen = Set<String>()
    let boundaryComplete = try boundary.forEachGroupItem(shouldStop: { false }) { reference, candidate, isReference in
        if isReference { currentReference = reference.path; referenceCount += 1; checkEqual(reference.path, candidate.path) }
        else { checkEqual(currentReference, reference.path); checkFalse(reference.path == candidate.path) }
        checkTrue(seen.insert(candidate.path).inserted)
        checkTrue((reference.hash ^ candidate.hash).nonzeroBitCount <= 5)
        checkTrue(reference.path <= candidate.path); boundaryCount += 1
    }
    checkTrue(boundaryComplete); checkEqual(boundaryCount, 4); checkEqual(referenceCount, 2)
    checkFalse(seen.contains(boundaryItems[2].path)); checkFalse(seen.contains(boundaryItems[5].path))
    var exactMatches = 0
    checkEqual(try boundary.forEachGroupItem(maxDistance: 0, shouldStop: { false }) { _,_,_ in exactMatches += 1 }, true)
    checkEqual(exactMatches, 0)
    checkThrows(try boundary.forEachGroupItem(maxDistance: 6, shouldStop: { false }) { _,_,_ in })
    checkThrows(try boundary.forEachGroupItem(shouldStop: { false }) { _,_,_ in throw SimilarIndexFixtureError.stop })
    var afterThrow = 0
    checkEqual(try boundary.forEachGroupItem(shouldStop: { false }) { _,_,_ in afterThrow += 1 }, true)
    checkEqual(afterThrow, 4)
    // Dense group exceeds 3000 as well: keyset LIMIT 1 is pagination only.
    let dense = try ScanSimilarityIndex.createTemporary(); defer { try? dense.dispose() }
    for number in (0..<3007).reversed() {
        try autoreleasepool { try dense.append(item(String(format: "dense-%05d", number), UInt64.max, number)) }
    }
    var denseCount = 0, denseReferences = 0, lastDense = ""
    checkEqual(try dense.forEachGroupItem(shouldStop: { false }) { reference, candidate, isReference in
        if isReference { denseReferences += 1 }
        checkTrue(reference.path.hasSuffix("dense-00000")); checkTrue(lastDense.isEmpty || lastDense < candidate.path)
        checkEqual(candidate.hash, UInt64.max); lastDense = candidate.path; denseCount += 1
    }, true)
    checkEqual(denseCount, 3007); checkEqual(denseReferences, 1); checkTrue(lastDense.hasSuffix("dense-03006"))
    let densePath = dense.temporaryReference.path
    try dense.dispose(); checkFalse(fm.fileExists(atPath: densePath))
    checkThrows(try dense.append(item("after-dispose", 0, 9999)))
    let sparsePath = sparse.temporaryReference.path, boundaryPath = boundary.temporaryReference.path
    try sparse.dispose(); try boundary.dispose()
    checkFalse(fm.fileExists(atPath: sparsePath)); checkFalse(fm.fileExists(atPath: boundaryPath))
    checkEqual(try String(contentsOf: source, encoding: .utf8), "metadata-only indices must not read or modify this fixture")
    print("PASS six-segment similarity index: 3201 sparse + 3007 dense rows, radius 5/6, UInt64 edges, cancellation, lexical reference")
}
