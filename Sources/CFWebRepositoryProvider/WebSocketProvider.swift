//
//  WebSocketProvider.swift
//  Swapmeter
//
//  Created by Dove Zachary on 2023/12/28.
//

import Foundation
#if canImport(OSLog)
import OSLog
#else
import Logging
#endif

public protocol WebSocketProvider: AnyObject {
    associatedtype ResponseMessage: Decodable
    
    var logger: Logger { get }
    
    var socketURL: URL? { get }
    var stream: WebSocketStream? { get set }
    var socketSession: URLSession { get }
    
    var responseMessageDecoder: JSONDecoder { get }
    var streamTask: Task<Void, Never>? { get set }

    func handleMessage(_ message: ResponseMessage) throws
}

extension WebSocketProvider {
    internal func handleMessage(_ message: URLSessionWebSocketTask.Message) throws {
        switch message {
            case .data(let data):
                try handleMessage(data)
            case .string(let string):
                try handleMessage(string)
            @unknown default:
                break
        }
    }
    
    internal func handleMessage(_ data: Data) throws {
        let message = try responseMessageDecoder.decode(ResponseMessage.self, from: data)
        try self.handleMessage(message)
    }
    
    internal func handleMessage(_ message: String) throws {
        guard let data = message.data(using: .utf8) else { return }
        let message = try responseMessageDecoder.decode(ResponseMessage.self, from: data)
        try self.handleMessage(message)
    }
    
    public func initSocket() {
        guard let url = self.socketURL else { return }
        self.streamTask?.cancel()
        self.streamTask = nil
        
        self.stream = WebSocketStream(url: url, session: socketSession)
        self.streamTask = Task { [stream] in
            do {
                for try await message in stream! {
                    try self.handleMessage(message)
                }
            } catch {
                logger.error("\(error)")
            }
        }
        Task { await self.streamTask?.result }
    }
}
