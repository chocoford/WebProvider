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
        socket.resume()
        listenForMessages()
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
    
    private var messageQueue: [Message] = []
    
    private var listenerTask: Task<Void, Never>? = nil
    
    /// indicate the web socket is open
    private(set) var isSocketOpen: Bool = false {
        didSet {
            if isSocketOpen {
                self.listenerTask = Task {
                    for message in messageQueue {
                        logger.debug("send queued message: \(message.message)")
                        do {
                            try await socket.send(message.message)
                        } catch {
                            self.messageQueue.retry(message)
                        }
                    }
                }
                Task { await self.listenerTask?.result }
            } else {
                self.listenerTask?.cancel()
                self.listenerTask = nil
            }
        }
    }
    /// indicate `WebSocketStream` to start clear waitlist.
    public var isSocketReady: Bool = false
        
    var status: URLSessionTask.State {
        socket.state
    }
    
    public var closeCode: String {
        String(describing: socket.closeCode)
    }
    
    public var closeReason: String {
        guard let reason = socket.closeReason else { return "Unknown" }
        let json = try? JSONSerialization.jsonObject(with: reason)
        return String(describing: json)
    }
    
    init(url: URL, session: URLSession = URLSession.shared) {
        logger.info("initing websocket: \(url.description)")
        socket = session.webSocketTask(with: url)
        super.init()
        
        socket.delegate = self
        stream = AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.continuation?.onTermination = { @Sendable [socket] _ in
                socket.cancel()
            }
        }
    }
    
    func ping() {
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
                    self.listenForMessages()
                case .failure(let error):
                    self.continuation?.finish(throwing: error)
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
        }
    }
}

extension WebSocketStream {
    public enum WebSocketStreamError: LocalizedError {
        case encodingError
    }

    public func send(data: Codable) async throws {
        logger.info("send data: \(String(describing: data))")
        let data = try JSONEncoder().encode(data)
        
        guard isSocketOpen else {
            messageQueue.append(Message(message: .data(data)))
            return
        }
        try await socket.send(.data(data))
    }
    
    public func send(message: Codable, force: Bool = false) async throws {
        let data = try JSONEncoder().encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WebSocketStreamError.encodingError
        }
        guard isSocketOpen else {
            messageQueue.append(Message(message: .string(string)))
            return
        }
        logger.info("send message: \(string)")
        try await socket.send(.string(string))
        
    }
    
    public func send(message: String) async throws {
        guard isSocketOpen else {
            messageQueue.append(Message(message: .string(message)))
            return
        }
        logger.info("send message: \(String(describing: message))")
        try await socket.send(.string(message))

    }
    
}

extension WebSocketStream: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("Web socket opened")
        isSocketOpen = true
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("Web socket closed, reason: \(self.closeReason)")
        isSocketOpen = false
    }
}
