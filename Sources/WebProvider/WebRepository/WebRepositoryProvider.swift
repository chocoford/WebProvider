//
//  WebRepositoryProvider.swift
//  
//
//  Created by Chocoford on 2023/3/17.
//

import Foundation
#if !os(Linux)
import Combine
#endif

#if canImport(OSLog)
import OSLog
#else
import Logging
#endif


#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LogOption {
    case request
    case response
    case data
    case error
}

//public protocol WebRepositoryProvider {
//    var logLevel: [LogOption] { get set }
//    var logger: Logger { get }
//    var session: URLSession { get }
//    var baseURL: String { get }
//    var bgQueue: DispatchQueue { get }
//    var responseDataDecoder: JSONDecoder { get set }
//    
//    var hooks: WebRepositoryHook { get }
//    
//    associatedtype APICalls
//    var requestsQueue: [String : APICalls] { get }
//}

open class WebRepository {
    public var logLevel: [LogOption]
    var logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "WebRepositoryProvider")
    var baseURL: URL
    var session: URLSession
    var bgQueue: DispatchQueue = DispatchQueue(label: "web_repo_bg_queue")
    
    public var hooks: WebRepositoryHook = .init()
    var responseDataDecoder: JSONDecoder
    
    private var requestsQueue: [String : [any APICall]] = [:]
    private let ongoingCallsQueue = DispatchQueue(label: "WebRepository-ongoingCallsQueue", qos: .background)
    private var ongoingCalls: [String : [Date]] = [:]
    private var semaphores: [String : DispatchSemaphore] = [:]
    private let semaphoreQueue = DispatchQueue(label: "WebRepository-semaphoreQueue", qos: .background)

    public init(
        logLevel: [LogOption] = [.error],
        baseURL: URL,
        session: URLSession = .shared,
        responseDataDecoder: JSONDecoder
    ) {
        self.logLevel = logLevel
        self.baseURL = baseURL
        self.session = session
        self.responseDataDecoder = responseDataDecoder
    }
}


public struct WebRepositoryHook {
    public var beforeEach: (APICallInstance) -> APICallInstance = { return $0 }
//    var afterEach: () -> Void
    
    public var unauthorizeHandler: () -> Void = { }
    public init(unauthorizeHandler: @escaping () -> Void = { }) {
        self.unauthorizeHandler = unauthorizeHandler
    }
}

extension WebRepository {
//    var logLevel: [LogOption] { [.error] }
    public func call<Value>(
        endpoint: APICall,
        httpCodes: HTTPCodes = .success
    ) async throws -> Value where Value: Decodable {
        let endpoint = self.hooks.beforeEach(endpoint.instantiate())
        
        while !(await canCall(endpoint)) {
            try await Task.sleep(nanoseconds: UInt64(50 * 1e+6))
        }
        
        await waitSemaphore(endpoint: endpoint) {
            ongoingCallsQueue.sync {
                if ongoingCalls[endpoint.path] == nil {
                    ongoingCalls[endpoint.path] = []
                }
                ongoingCalls[endpoint.path]!.append(Date())
            }
        }
        
        do {
            let request = try endpoint.urlRequest(baseURL: baseURL)
            if logLevel.contains(.request) { logger.info("\(request.prettyDescription)") }
            let (data, response) = try await session.data(for: request)
            if logLevel.contains(.response) { logger.info("\(response)") }
            guard let code = (response as? HTTPURLResponse)?.statusCode else {
                throw APIError.unexpectedResponse
            }
            let dataString = data.prettyJSONStringified()
            guard httpCodes.contains(code) else {
                
                if code == 401 {
                    self.hooks.unauthorizeHandler()
                }
                
                let error = APIError.httpCode(
                    code,
                    reason: dataString//,
//                    headers: (response as? HTTPURLResponse)?.allHeaderFields
                )
                throw error
            }
                        
            if logLevel.contains(.data) {
                if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                   let data = try? JSONSerialization.data(
                    withJSONObject: jsonObject,
                    options: [.prettyPrinted, .sortedKeys]
                   ) {
                    logger.info("\(String(data: data, encoding: .utf8) ?? "")")
                } else {
                    logger.info("\(String(data: data, encoding: .utf8) ?? "")")
                }
            }
            do {
                let decoded = try responseDataDecoder.decode(Value.self, from: data)
                return decoded
            } catch {
                if Value.self == String.self {
                    logger.warning("warning: \(error)")
                    return (String(data: data, encoding: .utf8) ?? "") as! Value
                } else {
                    throw error
                }
            }
        } catch {
            if logLevel.contains(.error) {
                logger.error("\(error)")
            }
            throw error
        }
    }
    
    private func waitSemaphore<T>(endpoint: APICall, action: () -> T) async -> T {
        await withCheckedContinuation { continuation in
            semaphoreQueue.sync(flags: .inheritQoS) {
                if semaphores[endpoint.path] == nil {
                    semaphores[endpoint.path] = DispatchSemaphore(value: 1)
                }
                let semaphore: DispatchSemaphore = semaphores[endpoint.path]!
                semaphore.wait() // 确保线程安全
                defer { semaphore.signal() }
                continuation.resume()
            }
        }
        return action()
    }
    
    private func canCall(_ endpoint: APICall) async -> Bool {
        guard let rateLimit = endpoint.rateLimit else { return true }
        return await waitSemaphore(endpoint: endpoint) {
            let now = Date()
            ongoingCallsQueue.sync {
                if ongoingCalls[endpoint.path] == nil {
                    ongoingCalls[endpoint.path] = []
                }
                ongoingCalls[endpoint.path] = ongoingCalls[endpoint.path]!.filter {
                    now.timeIntervalSince($0) < rateLimit.interval
                }
            }
            return ongoingCalls[endpoint.path]!.count < rateLimit.times
        }
    }
}

//class SessionDelegate: NSObject, URLSessionTaskDelegate {
//    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
//        print("didComplete", task, error)
//    }
//}

#if !os(Linux)
// MARK: - Combine support
extension WebRepository {
    public func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) -> AnyPublisher<Value, Error> where Value: Decodable {
        do {
            let request = try endpoint.urlRequest(baseURL: baseURL)
            logger.info("\(request.prettyDescription)")
            return session
                .dataTaskPublisher(for: request)
                .requestJSON(httpCodes: httpCodes, decoder: responseDataDecoder, logger: logger, logLevel: logLevel)
                .mapError { error in
                    if self.logLevel.contains(.error) {
                        self.logger.error("\(error)")
                    }
                    return error
                }
                .eraseToAnyPublisher()
        } catch {
            if logLevel.contains(.error) {
                logger.error("\(error)")
            }
            return Fail<Value, Error>(error: error).eraseToAnyPublisher()
        }
    }
}

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
                                              reason: dataString//,
                                              /*headers: ($0.response as? HTTPURLResponse)?.allHeaderFields*/)
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
                            decoder: JSONDecoder,
                            logger: Logger? = nil,
                            logLevel: [LogOption] = [.data, .response]) -> AnyPublisher<Value, Error> where Value: Decodable {

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

#endif
