//
//  PackStore.swift
//  Test
//
//  Created by Giorgi Tchelidze on 8/15/25.
//

import Foundation

enum PackStore {
    private static let key = "installed-packs-v1"
    static func load() -> [PackDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let packs = try? JSONDecoder().decode([PackDescriptor].self, from: data)
        else { return [] }
        return packs
    }
    static func save(_ packs: [PackDescriptor]) {
        let data = try? JSONEncoder().encode(packs)
        UserDefaults.standard.set(data, forKey: key)
    }
}
