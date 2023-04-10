//
//  APICall.swift
//  CFWebRepositoryProvider
//
//  Created by Alexey Naumov on 23.10.2019.
//

import Foundation
import OSLog

public enum APIMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

public protocol APICall {
    var path: String { get }
    var method: APIMethod { get }
    var headers: [String: String]? { get }
    var gloabalQueryItems: Codable? { get }
    var queryItems: Codable? { get }
    func body() throws -> Data?
}


enum APIError: Error {
    case invalidURL
    case httpCode(HTTPCode, reason: String, headers: [AnyHashable: Any]?)
    case unexpectedResponse
    case imageDeserialization
    case parameterInvalid
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
            case .invalidURL: return "Invalid URL"
            case let .httpCode(code, reason, headers): return "Unexpected HTTP code: \(code), reason: \(reason), response headers: \(headers ?? [:])"
            case .unexpectedResponse: return "Unexpected response from the server"
            case .imageDeserialization: return "Cannot deserialize image from Data"
            case .parameterInvalid: return "Parameter invalid"
        }
    }
}

extension APICall {
    func urlRequest(baseURL: String) throws -> URLRequest {
        guard var urlBuilder = URLComponents(string: baseURL + path) else { throw APIError.invalidURL }
        configureQueryItems(urlBuilder: &urlBuilder)
        
        guard let url = urlBuilder.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.allHTTPHeaderFields = headers
        request.httpBody = try body()
        return request
    }
    
    func configureQueryItems(urlBuilder: inout URLComponents) {
        if urlBuilder.queryItems == nil {
            urlBuilder.queryItems = []
        }
        if let p = gloabalQueryItems {
            if urlBuilder.queryItems != nil {
                _ = urlBuilder.queryItems!.drop { item in
                    p.dictionary[item.name] != nil
                }
            }
            urlBuilder.queryItems! += p.dictionary.map{URLQueryItem(name: $0.key, value: String(describing: $0.value))}
        }
        if let p = queryItems {
            if urlBuilder.queryItems != nil {
                _ = urlBuilder.queryItems!.drop { item in
                    p.dictionary[item.name] != nil
                }
            }

            urlBuilder.queryItems! += p.dictionary.map{URLQueryItem(name: $0.key, value: String(describing: $0.value))}
        }
        if urlBuilder.queryItems!.count == 0 {
            urlBuilder.queryItems = nil
        }
    }
    
    public func makeBody<T: Encodable>(payload: T) throws -> Data {
        let dic = payload.dictionary
        if JSONSerialization.isValidJSONObject(dic) {
            return try JSONSerialization.data(withJSONObject: dic,
                                              options: [.prettyPrinted, .fragmentsAllowed])
        } else {
            throw APIError.parameterInvalid
        }
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
                    let payload = try JSONSerialization.jsonObject(with: body, options: [])
                    self.body = String(describing: payload)
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
