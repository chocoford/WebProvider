//
//  WebRepositoryProvider.swift
//  
//
//  Created by Dove Zachary on 2023/3/17.
//

import Foundation
import Combine
import OSLog

public enum LogOption {
    case response
    case data
}

public protocol WebRepositoryProvider {
    var logLevel: [LogOption] { get set }
    var logger: Logger { get }
    var session: URLSession { get }
    var baseURL: String { get }
    var bgQueue: DispatchQueue { get }
}

extension WebRepositoryProvider {

    public func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) -> AnyPublisher<Value, Error> where Value: Decodable {
        do {
            let request = try endpoint.urlRequest(baseURL: baseURL)
            logger.info("\(request.prettyDescription)")
            return session
                .dataTaskPublisher(for: request)
                .requestJSON(httpCodes: httpCodes, logger: logger, logLevel: logLevel)
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
    
    public func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) async throws -> Value where Value: Decodable {
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
    func requestData(httpCodes: HTTPCodes = .success,
                     logger: Logger? = nil,
                     logLevel: [LogOption] = [.data, .response]) -> AnyPublisher<Data, Error> {
        return tryMap {
            assert(!Thread.isMainThread)
            guard let code = ($0.1 as? HTTPURLResponse)?.statusCode else {
                throw APIError.unexpectedResponse
            }
            
            let dataString = String(data: $0.data, encoding: .utf8) ?? ""
            
            guard httpCodes.contains(code) else {
                let error = APIError.httpCode(code,
                                              reason: dataString,
                                              headers: ($0.response as? HTTPURLResponse)?.allHeaderFields)
                logger?.error("\(error.errorDescription ?? "")")
                throw error
            }
            logger?.debug("\(dataString)")

            return $0.0
        }
//            .extractUnderlyingError()
            .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == URLSession.DataTaskPublisher.Output {
    func requestJSON<Value>(httpCodes: HTTPCodes,
                            logger: Logger? = nil,
                            logLevel: [LogOption] = [.data, .response]) -> AnyPublisher<Value, Error> where Value: Decodable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        
        return requestData(httpCodes: httpCodes, logger: logger, logLevel: logLevel)
            .decode(type: Value.self, decoder: decoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func printResult(disabled: Bool = false) -> AnyPublisher<Self.Output, Self.Failure> {
        return self
            .map({ (data, res) in
                if disabled { return (data, res) }
                let json = try? JSONSerialization.jsonObject(with: data, options: [])
                if let objJson = json as? [String: Any] {
                    dump(objJson.debugDescription, name: "result")
                } else if let arrJson = json as? [[String: Any]] {
                    dump(arrJson, name: "result")
                }
                return (data, res)
            })
            .eraseToAnyPublisher()
    }
}

