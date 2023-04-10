//
//  File.swift
//  
//
//  Created by Dove Zachary on 2023/3/29.
//

import Foundation

extension Data {
    func prettyJSONStringified() -> String {
        guard let jsonObj = try? JSONSerialization.jsonObject(with: self),
              let data = try? JSONSerialization.data(withJSONObject: jsonObj) else {
            return String(data: self, encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
