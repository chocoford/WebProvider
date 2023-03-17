//
//  Encodable+Extension.swift
//  CSWang
//
//  Created by Dove Zachary on 2022/12/1.
//

import Foundation
extension Encodable {
    subscript(key: String) -> Any? {
        return dictionary[key]
    }
    var dictionary: [String: Any] {
        return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
    
    var description: String {
        return String(describing: self)
    }
    
    func jsonStringified(percentEncoding: Bool = false) throws -> String {
        let data = try JSONEncoder().encode(self)
        let stringified = String(data: data, encoding: String.Encoding.utf8) ?? ""
        if !percentEncoding {
            return stringified
        }
        if let encoded = stringified.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return encoded
        }
        return ""
    }
}
