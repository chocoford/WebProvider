//
//  Encodable+Extension.swift
//  CSWang
//
//  Created by Chocoford on 2022/12/1.
//

import Foundation
struct NotDictionaryError: Error {}

extension Encodable {
    @available(*, deprecated)
    var dictionary: [String: Any] {
        return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
    
    func dictionary(with encoder: JSONEncoder) throws -> [String: Any] {
        let res = try JSONSerialization.jsonObject(with: encoder.encode(self))
        if let res = res as? [String : Any] {
            return res
        } else {
            throw NotDictionaryError()
        }
        
    }
}
