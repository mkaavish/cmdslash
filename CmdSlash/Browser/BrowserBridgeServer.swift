import Foundation
import Network
import os

/// A minimal local HTTP server the Chrome extension polls (Docs/PLANNING.md §23) — deliberately
/// not Chrome's Native Messaging mechanism. Native Messaging spawns a fresh helper subprocess per
/// connection, which would mean building a separate binary just to bridge its stdin/stdout
/// framing back to this already-running app. A plain localhost HTTP server the extension's
/// background service worker polls is simpler, skips that extra moving part, and matches our
/// actual traffic pattern — one command, wait for one result, not a continuous stream.
///
/// Protocol: `GET /poll` returns the next pending command as JSON (or `{}` if none). `POST
/// /result` with `{"id", "success", "data"|"error"}` resolves the command with that id.
final class BrowserBridgeServer {
    static let shared = BrowserBridgeServer()
    static let port: NWEndpoint.Port = 57130

    struct BridgeError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "BrowserBridgeServer")
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cmdslash.browserbridge")

    private var pendingCommand: (id: String, json: [String: Any])?
    private var resultContinuations: [String: CheckedContinuation<[String: Any], Error>] = [:]
    /// A `/poll` connection currently held open waiting for a command (long-polling — see the
    /// note on `respond(to:on:)`'s `/poll` case for why).
    private var pollWaiter: NWConnection?
    private var pollWaiterTimeoutWorkItem: DispatchWorkItem?

    private init() {}

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: Self.port) else {
            logger.error("Failed to create browser bridge listener on port \(Self.port.rawValue)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.logger.error("Browser bridge listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        logger.notice("Browser bridge server listening on 127.0.0.1:\(Self.port.rawValue)")
    }

    /// Sends a command to the extension and suspends until it responds or times out. Only one
    /// command is ever in flight at a time, matching the app's own one-step-at-a-time execution.
    func sendCommand(action: String, params: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let id = UUID().uuidString
        let commandJSON: [String: Any] = ["id": id, "action": action, "params": params]

        do {
            return try await withThrowingTaskGroup(of: [String: Any].self) { group in
                group.addTask {
                    // withThrowingTaskGroup waits for EVERY child task to actually finish before
                    // it returns — not just the first one. A raw withCheckedThrowingContinuation
                    // never checks Task.isCancelled on its own, so without withTaskCancellationHandler
                    // explicitly resuming it, cancelling this task (e.g. once the timeout task below
                    // wins) would never make it finish — and the whole call would hang forever
                    // waiting for it, silently swallowing the timeout that was supposed to fire.
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                            self.queue.async {
                                self.resultContinuations[id] = continuation
                                // Deliver directly to a connection already long-polling /poll,
                                // rather than stashing it for a future poll — that's what makes
                                // command delivery near-instant instead of waiting for the next
                                // poll cycle.
                                if let waiter = self.pollWaiter {
                                    self.pollWaiterTimeoutWorkItem?.cancel()
                                    self.pollWaiterTimeoutWorkItem = nil
                                    self.pollWaiter = nil
                                    self.writeResponse(status: "200 OK", json: commandJSON, on: waiter)
                                } else {
                                    self.pendingCommand = (id: id, json: commandJSON)
                                }
                            }
                        }
                    } onCancel: {
                        self.queue.async {
                            if let continuation = self.resultContinuations.removeValue(forKey: id) {
                                continuation.resume(throwing: CancellationError())
                            }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw BridgeError(message: "Timed out waiting for the browser extension. Is Chrome open with the CmdSlash extension installed and enabled?")
                }
                guard let result = try await group.next() else {
                    throw BridgeError(message: "No result")
                }
                group.cancelAll()
                return result
            }
        } catch {
            queue.async {
                self.resultContinuations.removeValue(forKey: id)
                if self.pendingCommand?.id == id {
                    self.pendingCommand = nil
                }
            }
            throw error
        }
    }

    // MARK: - Minimal HTTP server

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.parseCompleteRequest(buffer) {
                self.respond(to: request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    /// Deliberately not a general-purpose HTTP parser — this only ever needs to understand
    /// simple GET/POST/OPTIONS requests with a JSON body from our own extension, not arbitrary
    /// or adversarial HTTP traffic.
    private static func parseCompleteRequest(_ buffer: Data) -> HTTPRequest? {
        guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEndRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            contentLength = Int(value) ?? 0
        }

        let bodyStart = headerEndRange.upperBound
        let availableBody = buffer[bodyStart...]
        guard availableBody.count >= contentLength else { return nil } // wait for the rest to arrive
        return HTTPRequest(method: method, path: path, body: Data(availableBody.prefix(contentLength)))
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            writeResponse(status: "204 No Content", json: nil, on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/poll"):
            // Long-polling, not an immediate {} response: a Manifest V3 background service
            // worker gets terminated after ~30s of inactivity, so infrequent short polls would
            // mean browser commands could take up to 30s to even be noticed. Holding the
            // connection open until a command arrives (or ~20s elapses) gives near-instant
            // delivery, and the in-flight request is itself what keeps the service worker alive
            // between commands — a request/response poll every second wouldn't reliably do that.
            queue.async {
                if let pending = self.pendingCommand {
                    self.pendingCommand = nil
                    self.writeResponse(status: "200 OK", json: pending.json, on: connection)
                    return
                }
                self.pollWaiterTimeoutWorkItem?.cancel()
                self.pollWaiter = connection
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, self.pollWaiter === connection else { return }
                    self.pollWaiter = nil
                    self.writeResponse(status: "200 OK", json: [:], on: connection)
                }
                self.pollWaiterTimeoutWorkItem = workItem
                self.queue.asyncAfter(deadline: .now() + 20, execute: workItem)
            }
        case ("POST", "/result"):
            guard
                let parsed = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                let id = parsed["id"] as? String
            else {
                writeResponse(status: "400 Bad Request", json: ["error": "malformed body"], on: connection)
                return
            }
            queue.async {
                if let continuation = self.resultContinuations.removeValue(forKey: id) {
                    if (parsed["success"] as? Bool) == true {
                        continuation.resume(returning: parsed)
                    } else {
                        let message = (parsed["error"] as? String) ?? "Unknown browser extension error"
                        continuation.resume(throwing: BridgeError(message: message))
                    }
                }
                self.writeResponse(status: "200 OK", json: ["ok": true], on: connection)
            }
        default:
            writeResponse(status: "404 Not Found", json: ["error": "not found"], on: connection)
        }
    }

    private func writeResponse(status: String, json: [String: Any]?, on connection: NWConnection) {
        let bodyData = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        // The extension's background service worker requests from a chrome-extension:// origin —
        // without these headers the browser blocks the response as a cross-origin failure.
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        response += "Access-Control-Allow-Headers: Content-Type\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = Data(response.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
