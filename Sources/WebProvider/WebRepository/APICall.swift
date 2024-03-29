//
//  APICall.swift
//  WebProvider
//
//  Created by Alexey Naumov on 23.10.2019.
//

import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
    case patch = "PATCH"
}


public struct APICallRateLimit {
    public var times: Int
    public var interval: TimeInterval
    
    public init(times: Int, interval: TimeInterval) {
        self.times = times
        self.interval = interval
    }
}

public protocol APICall {
    var path: String { get }
    var method: APIMethod { get }
    var headers: [String: String]? { get }
    var gloabalQueryItems: Encodable? { get }
    var queryItems: Encodable? { get }
    func body() throws -> Data?

    var rateLimit: APICallRateLimit? { get }
}

extension APICall {
    func instantiate() -> APICallInstance {
        APICallInstance(
            path: self.path,
            method: self.method,
            headers: self.headers,
            gloabalQueryItems: self.gloabalQueryItems,
            queryItems: self.queryItems,
            bodyFactory: {
                try self.body()
            },
            rateLimit: self.rateLimit
        )
    }
}

public struct APICallInstance: APICall {
    public var path: String
    public var method: APIMethod
    public var headers: [String : String]?
    public var gloabalQueryItems: (any Encodable)?
    public var queryItems: (any Encodable)?
    public var bodyFactory: () throws -> Data?
    public func body() throws -> Data? {
        try bodyFactory()
    }
    public var rateLimit: APICallRateLimit?
    init(
        path: String,
        method: APIMethod,
        headers: [String : String]? = nil,
        gloabalQueryItems: (any Encodable)? = nil,
        queryItems: (any Encodable)? = nil,
        bodyFactory: @escaping () throws -> Data?,
        rateLimit: APICallRateLimit? = nil
    ) {
        self.path = path
        self.method = method
        self.headers = headers
        self.gloabalQueryItems = gloabalQueryItems
        self.queryItems = queryItems
        self.rateLimit = rateLimit
        self.bodyFactory = bodyFactory
    }
}


enum APIError {
    case invalidURL
    case httpCode(HTTPCode, reason: String/*, headers: [AnyHashable: Any]?*/)
    case unexpectedResponse
    case imageDeserialization
    case parameterInvalid
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
            case .invalidURL: return "Invalid URL"
            case let .httpCode(code, reason/*, headers*/):
                return "HTTP code error: \(code), reason: \(reason)"
            case .unexpectedResponse: return "Unexpected response from the server"
            case .imageDeserialization: return "Cannot deserialize image from Data"
            case .parameterInvalid: return "Parameter invalid"
        }
    }
    
    var failureReason: String? {
        switch self {
            case let .httpCode(_, reason/*, headers*/): 
                return reason
            default:
                return nil
        }
    }
}

extension APICall {
    var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom({ date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int(date.timeIntervalSince1970))
        })
        return encoder
    }
    
    func urlRequest(baseURL: URL) throws -> URLRequest {
        let url: URL
        
        if #available(iOS 16.0, macOS 13.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            url = baseURL.appending(path: path)
        } else {
            url = baseURL.appendingPathComponent(path)
        }
        
        guard var urlBuilder = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }
        
        try self.configureQueryItems(urlBuilder: &urlBuilder)
        
        guard let url = urlBuilder.url else {
            throw APIError.invalidURL
        }
        return try urlRequest(url: url)
    }
    
    func urlRequest(baseURL: String) throws -> URLRequest {
        guard var urlBuilder = URLComponents(string: baseURL + path) else { throw APIError.invalidURL }
        try self.configureQueryItems(urlBuilder: &urlBuilder)
        
        guard let url = urlBuilder.url else {
            throw APIError.invalidURL
        }
        return try urlRequest(url: url)
    }
    
    func urlRequest(url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.allHTTPHeaderFields = headers
        request.httpBody = try body()
        return request
    }
    
    func configureQueryItems(urlBuilder: inout URLComponents) throws {
        if urlBuilder.queryItems == nil {
            urlBuilder.queryItems = []
        }
        if let p = self.gloabalQueryItems {
            let dic = try p.dictionary(with: self.encoder)
            if urlBuilder.queryItems != nil {
                _ = urlBuilder.queryItems!.drop { item in
                    dic[item.name] != nil
                }
            }
            urlBuilder.queryItems! += dic.map{
                URLQueryItem(name: $0.key, value: String(describing: $0.value))
            }
        }
        if let p = self.queryItems {
            let dic = try p.dictionary(with: self.encoder)
            if urlBuilder.queryItems != nil {
                _ = urlBuilder.queryItems!.drop { item in
                    dic[item.name] != nil
                }
            }
            
            urlBuilder.queryItems! += dic.map{
                URLQueryItem(name: $0.key, value: String(describing: $0.value))
            }
        }
        if urlBuilder.queryItems!.count == 0 {
            urlBuilder.queryItems = nil
        }
    }
    
    public func makeBody<T: Encodable>(payload: T) throws -> Data {
        return try self.encoder.encode(payload)
    }
    
    public func makeFormData<T: Encodable>(payload: T, boundary: String) throws -> Data {
        var data = Data()
        
        for (key, value) in try payload.dictionary(with: self.encoder) {
            data.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(key)\"\"\r\n".data(using: .utf8)!)
            if let stringValue = value as? String,
                let d = stringValue.data(using: .utf8) {
                data.append(d)
            }
        }
        // Add the image data to the raw http request data
        
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}


extension URLRequest {
    struct Description: Codable {
        let method: String
        let href: String
        let headers: [String: String]
        let body: String
        
        init(with request: URLRequest) {
            self.method = request.httpMethod ?? "Unknown"
            self.href = request.url?.absoluteString ?? "Unknown"
            self.headers = request.allHTTPHeaderFields ?? [:]

            if let body = request.httpBody {
                do {
                    if JSONSerialization.isValidJSONObject(body) {
                        let payload = try JSONSerialization.jsonObject(with: body, options: [])
                        self.body = String(describing: payload)
                    } else if let string = String(data: body, encoding: .utf8) {
                        self.body = string
                    } else {
                        self.body = "serialize error"
                    }
                } catch {
                    self.body = "serialize error"
                }
            } else {
                self.body = "Never"
            }
        }
    }
    
    var prettyDescription: String {
        let description = Description(with: self)
        guard let encoded = try? JSONEncoder().encode(description),
              let object = try? JSONSerialization.jsonObject(with: encoded, options: []),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyPrintedString = String(data: data, encoding: .utf8) else { return "" }
        return prettyPrintedString.replacingOccurrences(of: "\\/", with: "/")
    }
}

public typealias HTTPCode = Int
public typealias HTTPCodes = Range<HTTPCode>

extension HTTPCodes {
    public static let success = 200 ..< 300
}
