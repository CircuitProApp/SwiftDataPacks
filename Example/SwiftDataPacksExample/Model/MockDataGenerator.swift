//
//  MockDataGenerator.swift
//  SwiftDataPacksExample
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation
import SwiftData

struct MockDataGenerator {
    
    // Enum to define the properties of each component category
    enum ComponentType: String, CaseIterable {
        case resistors = "Resistors"
        case capacitors = "Capacitors"
        case inductors = "Inductors"
        case integratedCircuits = "ICs"

        var prefix: String {
            switch self {
            case .resistors: return "R"
            case .capacitors: return "C"
            case .inductors: return "L"
            case .integratedCircuits: return "U"
            }
        }

        var values: [String] {
            switch self {
            case .resistors:
                return ["10Ω", "100Ω", "220Ω", "470Ω", "1kΩ", "4.7kΩ", "10kΩ", "100kΩ", "1MΩ"]
            case .capacitors:
                return ["10pF", "100pF", "1nF", "10nF", "100nF", "1µF", "10µF", "100µF"]
            case .inductors:
                return ["1µH", "10µH", "100µH", "1mH", "10mH", "100mH"]
            case .integratedCircuits:
                return ["NE555", "LM741", "ATmega328P", "74HC595", "L293D", "MCP3008"]
            }
        }

        var footprints: [String] {
            switch self {
            case .resistors, .capacitors, .inductors:
                return ["0402", "0603", "0805", "1206", "TH_Axial"]
            case .integratedCircuits:
                return ["DIP-8", "SOIC-8", "TSSOP-14", "DIP-16", "SOIC-16", "QFP-32"]
            }
        }
    }

    /// Seeds a context with a specific type of mock Component and its associated Footprints.
    static func generate(context: ModelContext, type: ComponentType, items: Int) throws {
        // Get a shuffled list of unique values for this run.
        let uniqueValues = type.values.shuffled()
        
        // Ensure we don't try to create more items than we have unique values for.
        let creationCount = min(items, uniqueValues.count)
        
        for i in 0..<creationCount {
            let value = uniqueValues[i]
            
            // --- Create a Component ---
            let componentName = "\(type.prefix)-\(value)"
            let component = Component(name: componentName)
            context.insert(component)
            
            // --- Create associated Footprints ---
            // Give each component a random subset of its possible footprints.
            let availableFootprints = type.footprints.shuffled()
            let footprintCount = Int.random(in: 1...min(3, availableFootprints.count))
            
            for j in 0..<footprintCount {
                let footprintName = availableFootprints[j]
                let footprint = Footprint(name: footprintName, component: component)
                context.insert(footprint)
            }
        }
    }
}
