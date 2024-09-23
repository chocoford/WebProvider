//
//  WebSocketRepository.swift
//
//
//  Created by Dove Zachary on 2024/3/20.
//

import Foundation
#if canImport(OSLog)
import OSLog
#else
import Logging
#endif
#if canImport(Combine)
import Combine
#endif

public class WebSocketRepository<Provider: WebSocketProvider> {
    var logger: Logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WebProvider",
        category: "WebSocketProvider"
    )
    
    public var urlRequest: URLRequest {
        get {
            self.provider.urlRequest
        }
        set {
            self.provider.urlRequest = newValue
            self.initSocketStream()
        }
    }
    public var session: URLSession {
        get { provider.session }
        set { provider.session = newValue }
        }
    
    public private(set) var stream: WebSocketStream?
    public var state: WebSocketStream.State {
        get {
            stream?.state ?? .notConnected
        }
        set {
            stream?.state = newValue
        }
    }
    
    public var pingInterval: TimeInterval? {
        didSet {
            self.setPingTimer()
        }
    }
    
    
    private var pingTimer: Timer?
    public var provider: Provider
    private var streamTask: Task<Void, Never>?

#if canImport(Combine)
    public var idSeeker: ((Data) throws -> Any?)?
    private var decodeClues: [MessageID : PassthroughSubject<Data, SendAndWaitError>] = [:]
    private var cancellables: [UUID : AnyCancellable] = [:]
#endif

    public init(url: URL, pingInterval: TimeInterval? = nil) where Provider == SimpleWebSocketProvider {
        self.provider = SimpleWebSocketProvider(url: url)
    }
    
    public init(provider: Provider, pingInterval: TimeInterval? = nil) {
        self.provider = provider
    }
    
    deinit {
        self.pingTimer?.invalidate()
    }
    
    
    private var autoReconnect = false
    
    public func autoConnect() -> Self {
        self.initSocketStream()
        self.connect(true)
        return self
    }
    
    
    // Callbacks
    public var onConnected: (() -> Void)?
    public var onDisconnected: ((Error?) -> Void)?
    public var onStringMessage: ((String) -> Void)?
    public var onDataMessage: ((Data) -> Void)?
}

extension WebSocketRepository {
    /// connect, the function will return if connect action done. Success or Fail.
    public func connect(_ autoReconnect: Bool = true) {
        self.stream?.connect()
        self.autoReconnect = autoReconnect
    }
    
    public func disconnect() {
        if case .closed = self.state { return }
        if case .notConnected = self.state { return }
        guard let stream = self.stream else { return }
        logger.info("Disconnecting <\(self.urlRequest.url?.absoluteString ?? "")>...")
        self.onDisconnected?(nil)
        self.streamTask?.cancel()
        self.streamTask = nil
        stream.close()
        state = .closed("")
        self.stream = nil
    }
    
    public func reconnect() {
        self.initSocketStream()
        self.connect(autoReconnect)
    }
    
    internal func initSocketStream() {
        self.disconnect()
        let stream = WebSocketStream(urlRequest: urlRequest, session: session) { [weak self] in
            guard let self = self else { return }
            self.logger.info("State changed: \($0)")
            switch $0 {
                case .notConnected:
                    break
                case .isConnecting:
                    break
                case .connected:
                    self.onConnected?()
                    self.setPingTimer()
                case .closed(_):
                    self.disconnect()
                    if self.autoReconnect == true {
                        DispatchQueue.global().asyncAfter(deadline: .now().advanced(by: .seconds(2))) {
                            self.reconnect()
                        }
                    }
            }
        }
        self.streamTask = Task { [weak stream] in
            guard let stream = stream else { return }
            do {
                for try await message in stream {
                    try self.handleMessage(message)
                }
            } catch {
                logger.error("\(error)")
            }
        }
        self.stream = stream
        Task { await self.streamTask?.result }
    }
    
    internal func setPingTimer() {
        guard let pingInterval = pingInterval else { return }
        if pingTimer != nil {
            pingTimer?.invalidate()
        }
        self.pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true, block: { timer in
            guard self.stream?.isSocketOpen == true else {
                timer.invalidate()
                return
            }
            self.stream?.ping()
        })
    }
    
    public func send<P: Encodable>(_ payload: P) async throws {
        try await self.stream?.send(message: payload)
    }
    
    #if canImport(Combine)
    struct SendAndWaitError: LocalizedError {
        var failureReason: String?
        var errorDescription: String?
        init(failureReason: String, errorDescription: String) {
            self.failureReason = failureReason
            self.errorDescription = errorDescription
        }
    }
    /// Send message and wait for the return value.
    public func send<P: Encodable, ID: KeyPath<P, Hashable>, Value: Decodable>(_ payload: P, id decodeID: ID) async throws -> Value {
        let id = payload[keyPath: decodeID]
        return try await self.send(payload, id: id)
    }
    /// Send message and wait for the return value.
    public func send<P: Encodable, ID: Hashable, Value: Decodable>(_ payload: P, id decodeID: ID) async throws -> Value {
        if self.idSeeker == nil {
            throw SendAndWaitError(
                failureReason: "IDSeekerNotConfig",
                errorDescription: "You must config `idSeeker` to use the function."
            )
        }
        guard let id = MessageID(decodeID) else {
            throw SendAndWaitError(
                failureReason: "InvalidID",
                errorDescription: "Can not retrieve valid message id."
            )
        }
        let publisher = PassthroughSubject<Data, SendAndWaitError>()
        self.decodeClues.updateValue(publisher, forKey: id)
        try await self.stream?.send(message: payload)
        let uuid = UUID()
        let data = try await withThrowingTaskGroup(of: Data.self) { taskGroup in
            taskGroup.addTask {
                var cancellable: AnyCancellable?
                let data = try await withCheckedThrowingContinuation { continuation in
                    cancellable = publisher.sink(receiveCompletion: { result in
                        if case .failure(let error) = result {
                            continuation.resume(throwing: error)
                        }
                        self.cancellables.removeValue(forKey: uuid)
                    }, receiveValue: { message in
                        continuation.resume(returning: message)
                    })
                    self.cancellables[uuid] = cancellable!
                }
                return data
            }
            taskGroup.addTask {
                let timeoutError = SendAndWaitError(
                    failureReason: "Timeout",
                    errorDescription: "Timeout when waiting the response, please check the id seeker."
                )
                try await Task.sleep(nanoseconds: UInt64(1e+9 * 10))
                publisher.send(completion: .failure(timeoutError))
                throw timeoutError
            }
            while true {
                if let data = try await taskGroup.next() {
                    taskGroup.cancelAll()
                    return data
                }
            }
        }
        
        return try self.provider.responseMessageDecoder.decode(Value.self, from: data)
    }
    #else
    @available(*, unavailable, message: "Only supported when Combine framework is available.")
    /// Send message and wait for the return value.
    public func send<P: Encodable, ID: KeyPath<P, Hashable>, Value: Decodable>(_ payload: P, id decodeID: ID) async throws -> Value {}
    @available(*, unavailable, message: "Only supported when Combine framework is available.")
    /// Send message and wait for the return value.
    public func send<P: Encodable, ID: Hashable, Value: Decodable>(_ payload: P, id decodeID: ID) async throws -> Value {}
    #endif
    
    public func sendRaw(_ text: String) async throws {
        try await self.stream?.send(message: text)
    }
    
    internal func handleMessage(_ message: URLSessionWebSocketTask.Message) throws {
        switch message {
            case .data(let data):
                do {
                    self.onDataMessage?(data)
                    if let id = try MessageID(idSeeker?(data)),
                       let publisher = self.decodeClues[id] {
                        publisher.send(data)
                        publisher.send(completion: .finished)
                    }
                    try provider.handleMessage(data: data)
                } catch {
                    
                    logger.error("It seems you are encounter an error when handle socket message. Display the original message: \n\(String(reflecting: try? JSONSerialization.jsonObject(with: data)))")
                    throw error
                }
            case .string(let string):
                do {
                   
                    self.onStringMessage?(string)
                    if let data = string.data(using: .utf8),
                       let idSeeker = idSeeker,
                       let id = try MessageID(idSeeker(data)),
                       let publisher = self.decodeClues[id] {
                        publisher.send(data)
                        publisher.send(completion: .finished)
                    }
                    try provider.handleMessage(string: string)
                } catch {
                    logger.error("It seems you are encounter an error when handle socket message. Display the original message: \n\(String(reflecting: try? JSONSerialization.jsonObject(with: string.data(using: .utf8) ?? Data())))")
                    throw error
                }
            @unknown default:
                break
        }
    }
}


extension WebSocketRepository {
    public static func connectAny(onSuccess: (() -> Void)? = nil) where Provider == SimpleWebSocketProvider {
        let provider = WebSocketRepository(url: URL(string: "https://echo.websocket.org/")!)
        provider.initSocketStream()
        provider.connect()
        provider.onConnected = onSuccess
        
        DispatchQueue.main.asyncAfter(deadline: .now().advanced(by: .nanoseconds(Int(1e+9 * 30)))) {
            provider.disconnect()
        }
    }
}

extension WebSocketRepository {
    enum MessageID: Hashable {
        case string(String)
        case int(Int)
        
        init?(_ value: Any) {
            if let value = value as? String {
                self = .string(value)
            } else if let value = value as? Int {
                self = .int(value)
            } else {
                return nil
            }
        }
    }
}
