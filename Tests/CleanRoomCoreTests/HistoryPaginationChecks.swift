import Foundation
@testable import CleanRoomCore

func runHistoryPaginationChecks() throws {
    let s = CoreTests(); try s.setUpWithError(); defer { try? s.tearDownWithError() }
    let database = try SQLiteHistoryStore(url: s.root.appendingPathComponent("pagination/history.sqlite3"))
    // Equal timestamps exercise the UUID tie-breaker rather than relying on clock resolution.
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    for i in 0..<405 {
        let record = TrashRecord(originalPath: s.files.appendingPathComponent("\(i)").path, trashPath: s.root.appendingPathComponent("fake/\(i)").path, bytes: Int64(i))
        var object = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
        object["date"] = 123456789.0
        try database.insert(decoder.decode(TrashRecord.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    let first = try database.records(limit: 200)
    let cursor = TrashHistoryCursor(try unwrap(first.last))
    let second = try database.records(limit: 200, before: cursor)
    let third = try database.records(limit: 200, before: TrashHistoryCursor(try unwrap(second.last)))
    checkEqual(first.count, 200); checkEqual(second.count, 200); checkEqual(third.count, 5)
    checkEqual(Set((first + second + third).map(\.id)).count, 405)
    let previous = try database.records(limit: 200, after: TrashHistoryCursor(try unwrap(second.first)))
    checkEqual(previous.map(\.id), first.map(\.id))
    try database.remove(cursor.id)
    checkEqual(try database.records(limit: 200, before: cursor).map(\.id), second.map(\.id))
    let end = try database.records(limit: 200, before: TrashHistoryCursor(try unwrap(third.last)))
    checkTrue(end.isEmpty)
}
