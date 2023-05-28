//
//  KeychainHelper.swift
//  PleaseApp
//
//  Created by Chocoford on 2022/6/9.
//
/// [Persisting Sensitive Data Using Keychain in Swift](https://swiftsenpai.com/development/persist-data-using-keychain/)
#if !os(Linux)
import Foundation
public final class KeychainHelper {
    public static let standard = KeychainHelper()
    private init() {}
    
    private func save(_ data: Data, service: String, account: String) {
        // Create query
        let query: [CFString : Any] = [
            kSecValueData: data,
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        // Add data in query to keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            // Print out the error
            print("Error: \(status)")
        }
        
        
        /// if duplicate, will update it.
        if status == errSecDuplicateItem {
            // Item already exist, thus update it.
            let query: [CFString : Any] = [
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecClass: kSecClassGenericPassword,
            ]

            let attributesToUpdate = [kSecValueData: data] as CFDictionary

            // Update existing item
            SecItemUpdate(query as CFDictionary, attributesToUpdate)
        }
    }
    
    private func read(service: String, account: String) -> Data? {
        
        let query: [CFString : Any] = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword,
            kSecReturnData: true
        ]
        
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        
        return (result as? Data)
    }
    
    public func delete(service: String, account: String) {
        
        let query: [CFString : Any] = [
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecClass: kSecClassGenericPassword,
            ]
        
        // Delete item from keychain
        DispatchQueue.global().async {
            SecItemDelete(query as CFDictionary)
        }
        
    }
    
    public func save<T>(_ item: T, service: String, account: String) where T : Codable {
        
        do {
            // Encode as JSON data and save in keychain
            let data = try JSONEncoder().encode(item)
            save(data, service: service, account: account)
            
        } catch {
            assertionFailure("Fail to encode item for keychain: \(error)")
        }
    }
    
    public func read<T>(service: String, account: String) -> T? where T : Codable {
        
        // Read item data from keychain
        guard let data = read(service: service, account: account) else {
            return nil
        }
        
        // Decode JSON data to object
        do {
            let item = try JSONDecoder().decode(T.self, from: data)
            return item
        } catch {
            assertionFailure("Fail to decode item for keychain: \(error)")
            return nil
        }
    }
}
#endif
