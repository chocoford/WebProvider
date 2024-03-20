//
//  WebSocketStream.swift
//  Swapmeter
//
//  Created by Dove Zachary on 2023/12/26.
//

import Foundation
#if canImport(OSLog)
import OSLog
#else
import Logging
#endif

extension URLSessionWebSocketTask.Message: CustomStringConvertible {
    public var description: String {
        switch self {
            case .data(let data):
                ".data: \(String(data: data, encoding: .utf8) ?? "nil")"
            case .string(let string):
                ".string: \(string)"
            @unknown default:
                "unknown"
        }
    }
}

extension WebSocketStream {
    public struct Message {
        public var message: URLSessionWebSocketTask.Message
        public var failedTimes: Int = 0
        
        func retry() -> Message {
            Message(message: self.message, failedTimes: self.failedTimes + 1)
        }
    }
}

extension [WebSocketStream.Message] {
    mutating func retry(_ message: Element) {
        guard message.failedTimes < 3 else { return }
        self.append(message.retry())
    }
}

public class WebSocketStream: NSObject, AsyncSequence {
    public typealias Element = URLSessionWebSocketTask.Message
    public typealias AsyncIterator = AsyncThrowingStream<Element, Error>.Iterator
    public func makeAsyncIterator() -> AsyncIterator {
        guard let stream = stream else {
            fatalError("stream was not initialized")
        }
        return stream.makeAsyncIterator()
    }
#if canImport(OSLog)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "WebSocketStream")
#else
    private let logger = Logger(label: "WebSocketStream")
#endif
    
    private var stream: AsyncThrowingStream<Element, Error>?
    private var continuation: AsyncThrowingStream<Element, Error>.Continuation?
    private let socket: URLSessionWebSocketTask
    private let onStateChanged: (State) -> Void
    
    private var messageQueue: [Message] = []
    
    private var listenerTask: Task<Void, Never>? = nil
    
    /// indicate the web socket is open
    private(set) public var isSocketOpen: Bool = false {
        didSet {
            if isSocketOpen {
                self.listenerTask = Task { [weak self] in
                    for message in messageQueue {
                        logger.debug("send queued message: \(message.message)")
                        do {
                            try await self?.socket.send(message.message)
                        } catch {
                            self?.messageQueue.retry(message)
                        }
                    }
                }
                Task { [weak self] in await self?.listenerTask?.result }
            } else {
                self.listenerTask?.cancel()
                self.listenerTask = nil
            }
        }
    }
    /// indicate `WebSocketStream` to start clear waitlist.
    public var isSocketReady: Bool = false
        
    public var state: State = .notConnected
    
    public var closeCode: String {
        String(describing: socket.closeCode)
    }
    
    public var closeReason: String {
        guard let reason = socket.closeReason else { return "Unknown" }
        let json = try? JSONSerialization.jsonObject(with: reason)
        return String(describing: json)
    }
    
    public var onSocketClosed: (() -> Void)?
    
    init(
        urlRequest: URLRequest,
        session: URLSession = URLSession.shared,
        onStateChanged: @escaping (State) -> Void = {_ in }
    ) {
        socket = session.webSocketTask(with: urlRequest)
        self.onStateChanged = onStateChanged
        super.init()
        
        socket.delegate = self
        stream = AsyncThrowingStream { [weak self] continuation in
            self?.continuation = continuation
            self?.continuation?.onTermination = { @Sendable [weak socket] _ in
                socket?.cancel()
            }
        }
        listenForMessages()
    }
    
    deinit {
        self.continuation?.finish()
        socket.cancel()
    }
    
    public func connect() {
        logger.info("socket resume: \(self.socket)")
        // MARK: - Bug: Memory leak
        socket.resume()
        if state != .connected {
            state = .isConnecting
        }
    }
    
    public func ping() {
        self.logger.debug("send ping...")
        socket.sendPing { [weak self] error in
            if let error = error {
                self?.logger.error("ping error: \(error)")
            } else {
                self?.logger.debug("receive pong!")
            }
        }
    }
    
    private func listenForMessages() {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let message):
                    self.continuation?.yield(message)
                    if self.isSocketOpen {
                        self.listenForMessages()
                    }
                case .failure(let error):
                    self.continuation?.finish(throwing: error)
                    self.close()
            }
        }
    }
    
    private func waitForMessages() async {
        do {
            let message = try await socket.receive()
            continuation?.yield(message)
            await waitForMessages()
        } catch {
            continuation?.finish(throwing: error)
            self.close()
        }
    }
}

extension WebSocketStream {
    public enum WebSocketStreamError: LocalizedError {
        case encodingError
    }
    
    public enum State: CustomStringConvertible, Equatable {
        /// Before the first connected
        case notConnected
        
        case isConnecting
        /// The WebSocket successfully negotiated the handshake with the endpoint
        case connected
        /// Closed
        case closed(_ reason: String)
        
        public var description: String {
            switch self {
                case .notConnected:
                    "Not connnected"
                case .isConnecting:
                    "Connecting..."
                case .connected:
                    "Connected"
                case .closed(let reason):
                    "Closed: \(reason)"
            }
        }
    }

    public func send(data: Encodable) async throws {
        logger.info("send data: \(String(describing: data))")
        let data = try JSONEncoder().encode(data)
        
        guard isSocketOpen else {
            logger.info("socket is not ready, push to queue: \(String(describing: data))")
            messageQueue.append(Message(message: .data(data)))
            return
        }
        try await socket.send(.data(data))
    }
    
    public func send(message: Encodable, force: Bool = false) async throws {
        let data = try JSONEncoder().encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WebSocketStreamError.encodingError
        }
        guard isSocketOpen else {
            logger.info("socket is not ready, push to queue: \(String(describing: message))")
            messageQueue.append(Message(message: .string(string)))
            return
        }
        logger.info("send text message: \(string)")
        try await socket.send(.string(string))
        
    }
    
    public func send(message: String) async throws {
        guard isSocketOpen else {
            logger.info("socket is not ready, push to queue: \(message)")
            messageQueue.append(Message(message: .string(message)))
            return
        }
        logger.info("send text message: \(message)")
        try await socket.send(.string(message))

    }
    
    public func close() {
        self.socket.cancel(with: .normalClosure, reason: nil)
    }
}

extension WebSocketStream: URLSessionWebSocketDelegate {
    /// Tells the delegate that the WebSocket task successfully negotiated the handshake with the endpoint, indicating the negotiated protocol.
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("Socket opened: \(session)")
        isSocketOpen = true
        self.state = .connected
        self.onStateChanged(self.state)
    }
    
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        print("Web socket closed, reason: \(self.closeReason)")
        isSocketOpen = false
        self.state = .closed(self.closeReason)
        self.onStateChanged(self.state)
    }
}
