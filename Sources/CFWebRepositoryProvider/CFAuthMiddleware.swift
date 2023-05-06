//
//  File.swift
//  
//
//  Created by Chocoford on 2023/3/17.
//

import Foundation
import OSLog

//protocol UserInfoRepresentable: Codable {
//    var token: String { get set }
//}
//
//protocol AuthMiddlewareProvider {
//    associatedtype UserInfo: UserInfoRepresentable
//
//    static var service: String { get }
//    static var account: String { get }
//
//    var logger: Logger { get }
//    var token: String? { get set }
//
//    func getTokenFromKeychain() -> UserInfo?
//    func saveTokenToKeychain(userInfo: UserInfo)
//    func updateToken(token: String)
//    func removeToken()
//}
//
//extension AuthMiddlewareProvider {
//    func getTokenFromKeychain() -> UserInfo? {
//        guard let userInfo: UserInfo = KeychainHelper.standard.read(service: Self.service,
//                                                                    account: Self.account) else {
//            logger.info("no auth info.")
//            return nil
//        }
//
//        self.token = userInfo.token
//
//        return userInfo
//    }
//
//
//    func saveTokenToKeychain(userInfo: UserInfo) {
//        guard userInfo.token != nil else {
//            return
//        }
//        KeychainHelper.standard.save(userInfo, service: Self.service, account: Self.account)
//        updateToken(token: userInfo.token!)
//    }
//
////    func updateToken(token: String) {
////        self.token = token
////    }
//
//    func removeToken() {
//        KeychainHelper.standard.delete(service: Self.service, account: Self.account)
////        self.token = nil
//    }
//}
//
//class CFAuthMiddleware: AuthMiddlewareProvider {
//    static var service: String = ""
//    static var account: String = ""
//
//    var token: String?
//
//    let logger: Logger = Logger(subsystem: "CFWebRepositoryProvider",
//                                category: "AuthMiddleware")
//
//}
