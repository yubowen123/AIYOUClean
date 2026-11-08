import Foundation
import CleanRoomCore
import CSQLite

private func privacyFixtureDB(_ url:URL,_ sql:String) throws -> OpaquePointer {
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    var db:OpaquePointer?
    guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,nil)==SQLITE_OK,let db else {throw BrowserPrivacyError.rejected("fixture database open failed")}
    guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {sqlite3_close(db);throw BrowserPrivacyError.rejected("fixture SQL failed")}
    return db
}
private func privacyCount(_ url:URL,_ table:String) throws -> Int64 {
    var db:OpaquePointer?;guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else {throw BrowserPrivacyError.rejected("fixture read failed")}
    defer {sqlite3_close(db)}
    var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM \"\(table)\"",-1,&statement,nil)==SQLITE_OK else {throw BrowserPrivacyError.rejected("fixture count prepare failed")}
    defer {sqlite3_finalize(statement)}
    guard sqlite3_step(statement)==SQLITE_ROW else {throw BrowserPrivacyError.rejected("fixture count failed")}
    return sqlite3_column_int64(statement,0)
}
private func privacyHistorySQL() -> String {
    """
    PRAGMA foreign_keys=ON;
    CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,visit_count INTEGER);
    CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER REFERENCES urls(id),visit_time INTEGER);
    CREATE TABLE visit_source(id INTEGER);
    CREATE TABLE keyword_search_terms(url_id INTEGER);
    CREATE TABLE segments(id INTEGER);
    CREATE TABLE segment_usage(segment_id INTEGER);
    CREATE TABLE downloads(id INTEGER PRIMARY KEY,target_path TEXT);
    CREATE TABLE downloads_url_chains(id INTEGER,url TEXT);
    INSERT INTO urls VALUES(1,'https://generated.fixture.invalid',1);
    INSERT INTO visits VALUES(1,1,100);
    INSERT INTO visit_source VALUES(1);
    INSERT INTO keyword_search_terms VALUES(1);
    INSERT INTO segments VALUES(1);
    INSERT INTO segment_usage VALUES(1);
    INSERT INTO downloads VALUES(1,'generated-file.txt');
    INSERT INTO downloads_url_chains VALUES(1,'https://generated.fixture.invalid/download');
    """
}

/// No user profile is read. Every database lives under this project's generated fixture directory.
func runPrivacyChecks() throws {
    let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root=project.appendingPathComponent(".test-fixtures/privacy-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let home=root.appendingPathComponent("home")
    let chrome=home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
    let firefox=home.appendingPathComponent("Library/Application Support/Firefox/Profiles/generated.default")
    let history=chrome.appendingPathComponent("History")
    let live=try privacyFixtureDB(history,"PRAGMA journal_mode=WAL;"+privacyHistorySQL())
    defer {sqlite3_close(live)}
    let cookie=chrome.appendingPathComponent("Network/Cookies")
    let chromeCookie=try privacyFixtureDB(cookie,"CREATE TABLE cookies(host_key TEXT,name TEXT,path TEXT,encrypted_value BLOB);INSERT INTO cookies VALUES('generated.invalid','fixture','/',X'0001');")
    sqlite3_close(chromeCookie)
    let places=firefox.appendingPathComponent("places.sqlite")
    let placeDB=try privacyFixtureDB(places,"""
    CREATE TABLE moz_places(id INTEGER PRIMARY KEY,url TEXT,visit_count INTEGER,last_visit_date INTEGER,recalc_frecency INTEGER,recalc_alt_frecency INTEGER);
    CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY,fk INTEGER REFERENCES moz_places(id));
    CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY,place_id INTEGER REFERENCES moz_places(id),visit_type INTEGER,visit_date INTEGER);
    CREATE TABLE moz_anno_attributes(id INTEGER PRIMARY KEY,name TEXT);
    CREATE TABLE moz_annos(id INTEGER PRIMARY KEY,anno_attribute_id INTEGER REFERENCES moz_anno_attributes(id),content TEXT);
    INSERT INTO moz_places VALUES(1,'https://generated-bookmark.invalid',1,100,0,0),(2,'https://generated-download.invalid',0,200,0,0);
    INSERT INTO moz_bookmarks VALUES(1,1);
    INSERT INTO moz_historyvisits VALUES(1,1,1,100),(2,2,7,200);
    INSERT INTO moz_anno_attributes VALUES(1,'downloads/metaData'),(2,'generated-other-note');
    INSERT INTO moz_annos VALUES(1,1,'generated metadata'),(2,2,'retained fixture');
    """)
    sqlite3_close(placeDB)
    let firefoxCookie=try privacyFixtureDB(firefox.appendingPathComponent("cookies.sqlite"),"CREATE TABLE moz_cookies(host TEXT,name TEXT,path TEXT,value TEXT);INSERT INTO moz_cookies VALUES('generated.invalid','fixture','/','generated-cookie-value');")
    sqlite3_close(firefoxCookie)
    let service=BrowserPrivacyService(storageRoot:root.appendingPathComponent("PrivacyBackups"),browserRunning:{_ in false})
    var report=service.scan(home:home)
    checkEqual(report.items.count,6);checkFalse(report.truncated)
    checkEqual(try privacyCount(history,"visits"),1)
    checkEqual(try privacyCount(cookie,"cookies"),1)
    let selected=try unwrap(report.items.first {$0.category == .chromeHistory})
    checkTrue(selected.tableCounts["visits"]==1)
    checkTrue(selected.records==6)
    let unconfirmed=service.clear([selected],confirmed:false)
    checkTrue(unconfirmed.receipts.isEmpty);checkFalse(unconfirmed.errors.isEmpty)
    let running=BrowserPrivacyService(storageRoot:root.appendingPathComponent("BlockedBackups"),browserRunning:{_ in true})
    let blocked=running.clear([selected],confirmed:true)
    checkTrue(blocked.receipts.isEmpty);checkTrue(blocked.errors.contains {$0.contains("退出")})
    let cleared=service.clear([selected],confirmed:true)
    checkTrue(cleared.errors.isEmpty);checkEqual(cleared.deletedRecords,6)
    checkEqual(try privacyCount(history,"visits"),0)
    checkEqual(try privacyCount(history,"urls"),0)
    checkEqual(try privacyCount(history,"downloads"),1)
    // A different connection is still open. Its live WAL must not be unlinked by this module.
    checkTrue(FileManager.default.fileExists(atPath:history.path+"-wal"))
    let receipt=try unwrap(cleared.receipts.first)
    checkEqual(receipt.state,.cleared)
    let backup=URL(fileURLWithPath:receipt.backupPath)
    checkEqual(try privacyCount(backup,"visits"),1)
    checkEqual(try privacyCount(backup,"downloads"),1)
    checkEqual(service.receipts().count,1)
    let exported=root.appendingPathComponent("exported-copy.sqlite")
    try service.exportBackup(receipt,to:exported,confirmed:true)
    checkEqual(try privacyCount(exported,"visits"),1)
    checkThrows(try service.exportBackup(receipt,to:history,confirmed:true))
    checkThrows(try service.exportBackup(receipt,to:exported,confirmed:true))
    checkThrows(try service.exportBackup(receipt,to:root.appendingPathComponent("not-confirmed.sqlite"),confirmed:false))
    // Original database changed after the earlier statistics: stale selection must not clear downloads.
    let staleDownloads=try unwrap(report.items.first {$0.category == .chromeDownloads})
    let stale=service.clear([staleDownloads],confirmed:true)
    checkTrue(stale.receipts.isEmpty);checkEqual(try privacyCount(history,"downloads"),1)
    report=service.scan(home:home)
    let firefoxHistory=try unwrap(report.items.first {$0.category == .firefoxHistory})
    let fxHistoryResult=service.clear([firefoxHistory],confirmed:true)
    checkTrue(fxHistoryResult.errors.isEmpty);checkEqual(fxHistoryResult.deletedRecords,1)
    checkEqual(try privacyCount(places,"moz_historyvisits"),1)
    checkEqual(try privacyCount(places,"moz_places"),2)
    checkEqual(try privacyCount(places,"moz_bookmarks"),1)
    report=service.scan(home:home)
    let fxDownloads=try unwrap(report.items.first {$0.category == .firefoxDownloads})
    let fxDownloadResult=service.clear([fxDownloads],confirmed:true)
    checkTrue(fxDownloadResult.errors.isEmpty);checkEqual(fxDownloadResult.deletedRecords,2)
    checkEqual(try privacyCount(places,"moz_historyvisits"),0)
    checkEqual(try privacyCount(places,"moz_annos"),1)
    checkEqual(try privacyCount(places,"moz_bookmarks"),1)
    report=service.scan(home:home)
    let cookies=report.items.filter {$0.category == .chromeCookies || $0.category == .firefoxCookies}
    let cookieResult=service.clear(cookies,confirmed:true)
    checkTrue(cookieResult.errors.isEmpty);checkEqual(cookieResult.deletedRecords,2)
    checkEqual(try privacyCount(cookie,"cookies"),0)
    // A protected external table blocks the later DELETE and must roll back earlier deletions.
    let rollbackHome=root.appendingPathComponent("rollback-home")
    let rollbackHistory=rollbackHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
    let rollbackDB=try privacyFixtureDB(rollbackHistory,privacyHistorySQL()+"CREATE TABLE retained_guard(url_id INTEGER REFERENCES urls(id) ON DELETE RESTRICT);INSERT INTO retained_guard VALUES(1);")
    sqlite3_close(rollbackDB)
    let rollbackItem=try unwrap(service.scan(home:rollbackHome).items.first {$0.category == .chromeHistory})
    let rollbackResult=service.clear([rollbackItem],confirmed:true)
    checkTrue(rollbackResult.receipts.isEmpty);checkFalse(rollbackResult.errors.isEmpty)
    checkEqual(try privacyCount(rollbackHistory,"visits"),1)
    checkEqual(try privacyCount(rollbackHistory,"visit_source"),1)
    // Custom persistent triggers are rejected before mutation.
    let triggerHome=root.appendingPathComponent("trigger-home")
    let triggerHistory=triggerHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
    let triggerDB=try privacyFixtureDB(triggerHistory,privacyHistorySQL()+"CREATE TRIGGER fixture_block BEFORE DELETE ON visits BEGIN SELECT RAISE(ABORT,'fixture blocker');END;")
    sqlite3_close(triggerDB)
    let triggerItem=try unwrap(service.scan(home:triggerHome).items.first {$0.category == .chromeHistory})
    let triggerResult=service.clear([triggerItem],confirmed:true)
    checkTrue(triggerResult.receipts.isEmpty);checkTrue(triggerResult.errors.contains {$0.contains("触发器")})
    checkEqual(try privacyCount(triggerHistory,"visits"),1)
    // Malformed schema is never classified as a supported Cookie database.
    let invalidHome=root.appendingPathComponent("invalid-home")
    let invalidCookie=invalidHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
    let invalidDB=try privacyFixtureDB(invalidCookie,"CREATE TABLE cookies(unknown TEXT);INSERT INTO cookies VALUES('generated');")
    sqlite3_close(invalidDB)
    let invalidReport=service.scan(home:invalidHome)
    checkTrue(invalidReport.items.isEmpty);checkTrue(invalidReport.warnings.contains {$0.contains("Schema")})
    let cancelled=service.scan(home:home,isCancelled:{true});checkTrue(cancelled.truncated);checkTrue(cancelled.items.isEmpty)
    let permit=try unwrap(WorkBudget.tryAcquire("privacy fixture contention"))
    let contention=service.clear([selected],confirmed:true);checkTrue(contention.errors.contains {$0.contains("正在运行")});permit.release()
    let again=WorkBudget.tryAcquire("privacy fixture release");checkTrue(again != nil);again?.release()
    // At most30 profile directories are processed; this only creates empty fixture directories.
    let manyHome=root.appendingPathComponent("many-home")
    let many=manyHome.appendingPathComponent("Library/Application Support/Google/Chrome")
    for i in 0..<35 {try FileManager.default.createDirectory(at:many.appendingPathComponent("Profile \(i)"),withIntermediateDirectories:true)}
    checkTrue(service.scan(home:manyHome).truncated)
    print("PASS privacy checks (read-only counts, WAL online backup, selected-category deletion, bookmark preservation, transactional rollback, stale/running/trigger/schema guards, non-overwriting backup export, cancellation and resource budget)")
}
