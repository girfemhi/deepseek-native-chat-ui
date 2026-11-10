//
//  File.swift
//  
//
//  Created by Alisa Mylnikova on 25.12.2023.
//

import Foundation

extension Array where Element: Identifiable {
    func hasUniqueIDs() -> Bool {
        var uniqueElements = Set<Element.ID>()
        uniqueElements.reserveCapacity(count)
        for el in self {
            guard uniqueElements.insert(el.id).inserted else { return false }
        }
        return true
    }
}
