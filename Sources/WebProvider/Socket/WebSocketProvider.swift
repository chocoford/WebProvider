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

struct SocketConnectError: LocalizedError {
    var errorDescription: String?
}


/// WebSocketProvider
public protocol WebSocketProvider {
    associatedtype ResponseMessage: Decodable
    
    var urlRequest: URLRequest { get set }
    var session: URLSession { get set }
    var responseMessageDecoder: JSONDecoder { get }
    func handleMessage(_ message: ResponseMessage) throws
}

public struct SimpleWebSocketProvider: WebSocketProvider {
    public var urlRequest: URLRequest
    
    public var session: URLSession = .shared
    
    public var responseMessageDecoder: JSONDecoder = JSONDecoder()
    
    public func handleMessage(_ message: String) throws {
        
    }
    
    init(urlRequest: URLRequest, session: URLSession, responseMessageDecoder: JSONDecoder) {
        self.urlRequest = urlRequest
        self.session = session
        self.responseMessageDecoder = responseMessageDecoder
    }
    
    init(url: URL) {
        self.urlRequest = URLRequest(url: url)
    }
}


extension WebSocketProvider {
    internal func handleMessage(data: Data) throws {
        if ResponseMessage.self == String.self { // ResponseMessage.self is String not work
            if let obj = try? JSONSerialization.jsonObject(with: data) {
                let data = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
                if let string = String(data: data, encoding: .utf8),
                   let string = string as? ResponseMessage {
                    try self.handleMessage(string)
                }
            } else if let string = String(data: data, encoding: .utf8),
                      let string = string as? ResponseMessage {
                try self.handleMessage(string)
            }
        } else if (try? JSONSerialization.isValidJSONObject(JSONSerialization.jsonObject(with: data))) == true {
            let message = try responseMessageDecoder.decode(ResponseMessage.self, from: data)
            try self.handleMessage(message)
        } else {
            print("Not decodable type: \(ResponseMessage.self)")
        }
    }
    
    internal func handleMessage(string message: String) throws {
        guard let data = message.data(using: .utf8) else { return }
        try self.handleMessage(data: data)
    }

}

