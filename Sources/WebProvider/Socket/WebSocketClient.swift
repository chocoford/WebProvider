//
//  WebSocketClient.swift
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

public class WebSocketClient<Provider: WebSocketProvider> {
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
    
    var pingInterval: TimeInterval? {
        didSet {
            self.setPingTimer()
        }
    }
    
    
    private var pingTimer: Timer?
    private var provider: Provider
    private var streamTask: Task<Void, Never>?
    
    public init(url: URL) where Provider == SimpleWebSocketProvider {
        self.provider = SimpleWebSocketProvider(url: url)
    }
    
    public init(provider: Provider) {
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

extension WebSocketClient {
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
    
    public func send<P: Encodable>(_ paylaod: P) async throws {
        try await self.stream?.send(message: paylaod)
    }
    public func sendRaw(_ text: String) async throws {
        try await self.stream?.send(message: text)
    }
    
    internal func handleMessage(_ message: URLSessionWebSocketTask.Message) throws {
        switch message {
            case .data(let data):
                self.onDataMessage?(data)
                try provider.handleMessage(data: data)
            case .string(let string):
                self.onStringMessage?(string)
                try provider.handleMessage(string: string)
            @unknown default:
                break
        }
    }
}


extension WebSocketClient {
    public static func connectAny(onSuccess: (() -> Void)? = nil) where Provider == SimpleWebSocketProvider {
        let provider = WebSocketClient(url: URL(string: "https://echo.websocket.org/")!)
        provider.initSocketStream()
        provider.connect()
        provider.onConnected = onSuccess
        
        DispatchQueue.main.asyncAfter(deadline: .now().advanced(by: .nanoseconds(Int(1e+9 * 30)))) {
            provider.disconnect()
        }
    }
}
