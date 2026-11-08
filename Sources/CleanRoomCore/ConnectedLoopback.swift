import Foundation
import Network

/// One-shot RFC 8252 listener. It binds the IPv4 loopback literal, never a wildcard interface.
/// The total received request bytes for the entire attempt are limited to 8 KiB.
public final class ConnectedLoopbackListener: @unchecked Sendable {
    private let configuration: ConnectedConfiguration
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "local.aiyou.AIYOUClean.oauth-loopback", qos: .userInitiated)
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var boundConfiguration: ConnectedConfiguration?
    private var request: ConnectedOAuthRequest?
    private var startContinuation: CheckedContinuation<ConnectedConfiguration, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var completed: Result<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var receivedBytes = 0
    private var started = false
    private var closed = false
    private var responsePending = false
    private let requestLimit = 8_192

    public init(configuration: ConnectedConfiguration, timeout: TimeInterval = 180) throws {
        guard configuration.validationIssue == nil, configuration.isGoogleLoopback, timeout > 0, timeout <= 180 else { throw ConnectedError.invalidConfiguration }
        self.configuration = configuration; self.timeout = timeout
    }
    public func start() async throws -> ConnectedConfiguration {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !started, !closed else { continuation.resume(throwing: ConnectedError.invalidConfiguration); return }
                    started = true; startContinuation = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                        parameters.allowLocalEndpointReuse = false; parameters.includePeerToPeer = false
                        let local = try NWListener(using: parameters, on: .any)
                        listener = local
                        local.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
                        local.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        let deadline = DispatchSource.makeTimerSource(queue: queue)
                        deadline.schedule(deadline: .now() + timeout)
                        deadline.setEventHandler { [weak self] in self?.finish(.failure(ConnectedError.expiredAuthorization)) }
                        timer = deadline; deadline.resume()
                        local.start(queue: queue)
                    } catch { finish(.failure(ConnectedError.loopbackUnavailable)) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard !closed, let port = listener?.port, port.rawValue != 0, var uri = URLComponents(string: configuration.redirectURI) else { finish(.failure(ConnectedError.loopbackUnavailable)); return }
            uri.port = Int(port.rawValue)
            guard let value = uri.string else { finish(.failure(ConnectedError.invalidConfiguration)); return }
            var c = configuration; c.redirectURI = value; boundConfiguration = c
            let continuation = startContinuation; startContinuation = nil; continuation?.resume(returning: c)
        case .failed: finish(.failure(ConnectedError.loopbackUnavailable))
        case .cancelled:
            if !closed { finish(.failure(ConnectedError.cancelled)) }
        default: break
        }
    }
    public func arm(_ request: ConnectedOAuthRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed, self.request == nil, request.configuration == boundConfiguration else { continuation.resume(throwing: ConnectedError.invalidConfiguration); return }
                self.request = request; continuation.resume()
            }
        }
    }
    public func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let completed { self.completed = nil; continuation.resume(with: completed); return }
                    guard !closed, request != nil, callbackContinuation == nil else { continuation.resume(throwing: ConnectedError.invalidConfiguration); return }
                    callbackContinuation = continuation
                }
            }
        }, onCancel: { self.cancel() })
    }
    public func cancel() { queue.async { [weak self] in self?.finish(.failure(ConnectedError.cancelled)) } }
    private func finish(_ result: Result<URL, Error>) {
        guard !closed else { return }
        closed = true; request = nil; responsePending = false
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        if let startContinuation {
            self.startContinuation = nil
            if case .failure(let error) = result { startContinuation.resume(throwing: error) }
            else { startContinuation.resume(throwing: ConnectedError.invalidConfiguration) }
        }
        if let callbackContinuation { self.callbackContinuation = nil; callbackContinuation.resume(with: result) }
        else { completed = result }
    }
    private func accept(_ connection: NWConnection) {
        guard !closed, connections.count < 2, case let .hostPort(host, _) = connection.endpoint,
              case let .ipv4(address) = host, address == .loopback else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.connections.removeValue(forKey: id); connection?.cancel()
            default: break
            }
        }
        connection.start(queue: queue); receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        guard !closed, receivedBytes < requestLimit else { finish(.failure(ConnectedError.invalidCallback)); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(1_024, requestLimit - receivedBytes)) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, !self.closed else { return }
            var bytes = accumulated
            if let data {
                self.receivedBytes += data.count
                guard self.receivedBytes <= self.requestLimit else { self.finish(.failure(ConnectedError.invalidCallback)); return }
                bytes.append(data)
            }
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.upperBound == bytes.endIndex else { self.respond(connection, id: id, success: false, terminal: nil); return }
                self.handle(bytes, connection: connection, id: id)
            } else if isComplete || error != nil {
                self.respond(connection, id: id, success: false, terminal: nil)
            } else { self.receive(connection, id: id, accumulated: bytes) }
        }
    }
    private func handle(_ bytes: Data, connection: NWConnection, id: UUID) {
        guard !responsePending, let request, let boundConfiguration, let uri = URLComponents(string: boundConfiguration.redirectURI), let port = uri.port,
              let raw = String(data: bytes, encoding: .utf8) else { respond(connection, id: id, success: false, terminal: nil); return }
        let lines = raw.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").components(separatedBy: " ")
        guard first.count == 3, first[0] == "GET", ["HTTP/1.1", "HTTP/1.0"].contains(first[2]), first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("#") else { respond(connection, id: id, success: false, terminal: nil); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { respond(connection, id: id, success: false, terminal: nil); return }
            let key = String(line[..<colon]).lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil, !key.isEmpty else { respond(connection, id: id, success: false, terminal: nil); return }
            headers[key] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0",
              let callback = URL(string: "http://127.0.0.1:\(port)" + first[1]) else { respond(connection, id: id, success: false, terminal: nil); return }
        do {
            _ = try request.validatedCode(from: callback)
            responsePending = true
            respond(connection, id: id, success: true, terminal: .success(callback))
        } catch ConnectedError.authorizationDenied {
            // A state-validated denial is terminal and must not wait for another callback.
            responsePending = true
            respond(connection, id: id, success: true, terminal: .failure(ConnectedError.authorizationDenied))
        } catch { respond(connection, id: id, success: false, terminal: nil) }
    }
    private func respond(_ connection: NWConnection, id: UUID, success: Bool, terminal: Result<URL, Error>?) {
        let body = success ? "<!doctype html><html><head><meta charset=\"utf-8\"><title>AIYOUClean</title></head><body>Authorization received. You may close this window.</body></html>" : "<!doctype html><html><head><meta charset=\"utf-8\"><title>AIYOUClean</title></head><body>Invalid authorization response.</body></html>"
        let status = success ? "200 OK" : "400 Bad Request"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((header + body).utf8), completion: .contentProcessed { [weak self, weak connection] _ in
            connection?.cancel()
            guard let self else { return }
            self.connections.removeValue(forKey: id)
            if let terminal { self.finish(terminal) }
        })
    }
}
