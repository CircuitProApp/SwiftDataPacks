//
//  ModelContainerProvider.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/20/25.
//

import SwiftData
import OSLog

private let logger = Logger(subsystem: "app.circuitpro.SwiftDataPacks", category: "ModelContainerProvider")

@MainActor
class ModelContainerProvider {
    private let schema: Schema
    private let userStoreURL: URL
    private let mainStoreIdentifier: String

    init(schema: Schema, userStoreURL: URL, mainStoreIdentifier: String) {
        self.schema = schema
        self.userStoreURL = userStoreURL
        self.mainStoreIdentifier = mainStoreIdentifier
    }

    /// Builds the main composite container including the user store and all valid packs.
    func buildMainContainer(for packs: [InstalledPack]) throws -> ModelContainer {
        var configurations: [ModelConfiguration] = [self.configurationForUserStore()]
        
        let validPackConfigs = packs.compactMap { pack -> ModelConfiguration? in
            guard let packConfig = self.configuration(for: .pack(id: pack.id), allPacks: packs) else { return nil }
            // Validate that each pack's container can be loaded individually
            do {
                _ = try ModelContainer(for: schema, configurations: [packConfig])
                return packConfig
            } catch {
                logger.warning("Excluding pack '\(pack.metadata.title)' from main container due to load error: \(error.localizedDescription)")
                return nil
            }
        }
        
        configurations.append(contentsOf: validPackConfigs)
        return try ModelContainer(for: schema, configurations: configurations)
    }

    // MARK: - Method signature corrected here to return ModelConfiguration?
    /// Creates a single ModelConfiguration for a given source. Returns nil if the source is invalid (e.g., pack not found).
    func configuration(for source: ContainerSource, allPacks: [InstalledPack]) -> ModelConfiguration? {
        switch source {
        case .mainStore:
            return configurationForUserStore()
        case .pack(let id):
            guard let pack = allPacks.first(where: { $0.id == id }) else {
                return nil // Return nil if the pack isn't in the provided list
            }
            return ModelConfiguration(pack.id.uuidString, schema: schema, url: pack.storeURL, allowsSave: pack.allowsSave)
        }
    }
    
    /// A private helper for creating the user store's configuration.
    private func configurationForUserStore() -> ModelConfiguration {
        return ModelConfiguration(mainStoreIdentifier, schema: schema, url: userStoreURL, allowsSave: true)
    }
}
