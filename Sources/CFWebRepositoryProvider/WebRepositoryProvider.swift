//
//  WebRepositoryProvider.swift
//  
//
//  Created by Dove Zachary on 2023/3/17.
//

import Foundation
import Combine
import OSLog

protocol WebRepositoryProvider {
    var logger: Logger { get }
    var session: URLSession { get }
    var baseURL: String { get }
    var bgQueue: DispatchQueue { get }
}

extension WebRepositoryProvider {
    func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) -> AnyPublisher<Value, Error>
    where Value: Decodable {
        do {
            let request = try endpoint.urlRequest(baseURL: baseURL)
            logger.info("\(request.prettyDescription)")
            return session
                .dataTaskPublisher(for: request)
//                .printResult()
                .requestJSON(httpCodes: httpCodes)
                .mapError {
                    dump($0)
                    logger.error("\($0.localizedDescription)")
                    return $0
                }
                .eraseToAnyPublisher()
        } catch let error {
            logger.error("\(error.localizedDescription)")
            return Fail<Value, Error>(error: error).eraseToAnyPublisher()
        }
    }
    
    func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) async throws -> Value
    where Value: Decodable {
        let request = try endpoint.urlRequest(baseURL: baseURL)
        logger.info("\(request.prettyDescription)")
        let (data, response) = try await session.data(for: request)
        logger.info("\(response)")
        do {
            let decoded = try JSONDecoder().decode(Value.self, from: data)
            return decoded
        } catch {
            dump(error)
            throw error
        }
    }
}

// MARK: - Helpers

extension Publisher where Output == URLSession.DataTaskPublisher.Output {
    func requestData(httpCodes: HTTPCodes = .success) -> AnyPublisher<Data, Error> {
        return tryMap {
                assert(!Thread.isMainThread)
                guard let code = ($0.1 as? HTTPURLResponse)?.statusCode else {
                    throw APIError.unexpectedResponse
                }
                guard httpCodes.contains(code) else {
                    var reason = ""
                    if let jsonObject = try? JSONSerialization.jsonObject(with: $0.data, options: []),
                       let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]) {
                        reason = String(data: data, encoding: .utf8) ?? ""
                    }
                    throw APIError.httpCode(code,
                                            reason: reason,
                                            headers: ($0.response as? HTTPURLResponse)?.allHeaderFields)
                }
                return $0.0
            }
//            .extractUnderlyingError()
            .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == URLSession.DataTaskPublisher.Output {
    func requestJSON<Value>(httpCodes: HTTPCodes) -> AnyPublisher<Value, Error> where Value: Decodable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        
        return requestData(httpCodes: httpCodes)
            .decode(type: Value.self, decoder: decoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func printResult() -> AnyPublisher<Self.Output, Self.Failure> {
        return self
            .map({ (data, res) in
                let json = try? JSONSerialization.jsonObject(with: data, options: [])
                if let objJson = json as? [String: Any] {
                    dump(objJson.debugDescription, name: "result")
                } else if
                    let arrJson = json as? [[String: Any]] {
                    dump(arrJson, name: "result")
                }
                return (data, res)
            })
            .eraseToAnyPublisher()
    }
}
