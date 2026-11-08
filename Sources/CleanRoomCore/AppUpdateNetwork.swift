import Foundation

public protocol AppUpdateTransport: Sendable {
    func fetch(_ url:URL,maximumBytes:Int64) async throws -> Data
    func download(_ url:URL,to destination:URL,maximumBytes:Int64) async throws
}
public struct AppUpdateHTTPSClient:AppUpdateTransport {
    public init() {}
    public func fetch(_ url:URL,maximumBytes:Int64) async throws -> Data {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("aiyou-update-feed-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        try await download(url,to:temp,maximumBytes:maximumBytes)
        return try Data(contentsOf:temp)
    }
    public func download(_ url:URL,to destination:URL,maximumBytes:Int64) async throws {
        try AppUpdateURLPolicy.validate(url); try Task.checkCancellation()
        let delegate=UpdateHTTPSDelegate(maximumBytes:maximumBytes)
        let config=URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies=false; config.httpCookieStorage=nil; config.urlCredentialStorage=nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=600
        let session=URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var request=URLRequest(url:url); request.setValue("AIYOUClean/0.2 (manual update check)",forHTTPHeaderField:"User-Agent")
        let (temp,response)=try await session.download(for:request,delegate:delegate)
        defer { try? FileManager.default.removeItem(at:temp) }
        try Task.checkCancellation()
        if let rejection=delegate.rejection { throw AppUpdateError.invalid(rejection) }
        guard let http=response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let final=http.url else { throw AppUpdateError.invalid("更新服务器未返回成功HTTP响应") }
        try AppUpdateURLPolicy.validate(final)
        let size=(try FileManager.default.attributesOfItem(atPath:temp.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size>=0, size<=maximumBytes else { throw AppUpdateError.invalid("下载超过大小上限") }
        guard !FileManager.default.fileExists(atPath:destination.path), !FileSafety.hasSymlinkComponent(destination.deletingLastPathComponent()) else { throw AppUpdateError.invalid("下载目标已存在或包含符号链接") }
        try FileManager.default.moveItem(at:temp,to:destination)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
    }
}
private final class UpdateHTTPSDelegate:NSObject,URLSessionDownloadDelegate,@unchecked Sendable {
    private let maxBytes:Int64
    private let lock=NSLock()
    private var _rejection:String?
    var rejection:String? { lock.lock(); defer { lock.unlock() }; return _rejection }
    init(maximumBytes:Int64) { maxBytes=maximumBytes }
    private func reject(_ text:String) { lock.lock(); _rejection=text; lock.unlock() }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        guard let u=request.url,(try? AppUpdateURLPolicy.validate(u)) != nil else { reject("拒绝更新服务器重定向到非HTTPS地址"); completionHandler(nil); task.cancel(); return }
        completionHandler(request)
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten>maxBytes || totalBytesExpectedToWrite>maxBytes { reject("下载超过大小上限"); downloadTask.cancel() }
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {}
}
