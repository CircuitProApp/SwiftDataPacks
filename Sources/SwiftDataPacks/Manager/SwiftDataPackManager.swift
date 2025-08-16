//
//  SwiftDataPackManager.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation
import SwiftUI
import SwiftData
import Observation
import OSLog

private let logger = Logger(subsystem: "app.circuitpro.SwiftDataPacks", category: "SwiftDataPackManager")

@Observable
@MainActor
public final class SwiftDataPackManager {
    // MARK: - Public Containers

    /// A read-write container for the user's data ONLY. Use for all insertions via `performWrite`.
    private(set) var userContainer: ModelContainer
    
    /// A read-only container for all installed packs ONLY.
    private(set) var packsContainer: ModelContainer

    /// The main, composite container of all stores for unified display.
    /// This should be the default container for the app's views.
    private(set) var mainContainer: ModelContainer

    // MARK: - Public State
    
    /// Provides public, read-only access to the list of installed packs from the registry.
    public var installedPacks: [InstalledPack] {
        registry.packs
    }

    /// The top-level directory on disk where all pack folders are stored.
    public var packsDirectoryURL: URL {
        storage.packsDirectoryURL
    }

    // MARK: - Core State & Delegates
    
    let schema: Schema
    let rootURL: URL
    let config: SwiftDataPackManagerConfiguration
    private let storage: PackStorageManager
    private let registry: PackRegistry

    // MARK: - Initialization

    public init(for models: [any PersistentModel.Type], config: SwiftDataPackManagerConfiguration) throws {
        self.config = config
        self.schema = Schema(models)

        // 1. Establish Root Directory
        let fm = FileManager.default
        guard let appIdentifier = Bundle.main.bundleIdentifier ?? Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String else {
            throw PackManagerError.initializationFailed(reason: "Cannot determine app bundle identifier.")
        }
        
        do {
            let appSupportURL = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.rootURL = appSupportURL.appendingPathComponent(appIdentifier, isDirectory: true)
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            logger.info("SwiftDataPackManager root URL: \(self.rootURL.path)")

            // 2. Initialize Delegated Managers
            self.storage = PackStorageManager(rootURL: rootURL, schema: schema)
            let registryURL = self.storage.packsDirectoryURL.appendingPathComponent("installed_packs.json")
            self.registry = PackRegistry(storeURL: registryURL)
            
            // 3. Bootstrap File System & Build Containers
            try self.storage.bootstrap()
            let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            try Self.ensureStoreExists(at: mainStoreURL, schema: schema)

            let result = try Self.buildAllContainers(
                schema: schema,
                mainStoreURL: mainStoreURL,
                mainStoreName: config.mainStoreName,
                packs: registry.packs
            )
            self.userContainer = result.user
            self.packsContainer = result.packs
            self.mainContainer = result.main
            
            if !result.excluded.isEmpty {
                let titles = result.excluded.map { $0.metadata.title }.joined(separator: ", ")
                logger.warning("Excluded packs at launch: \(titles)")
            }
        } catch {
            throw PackManagerError.initializationFailed(reason: error.localizedDescription)
        }

        // 4. Perform initial cleanup
        storage.emptyQuarantine()
    }
    
    // MARK: - Public Write API
    
    /// Executes a write operation within a dedicated context that can only see the user's main store.
    /// This is the sole, safe entry point for all insertions and modifications.
    /// - Parameter block: A closure that receives a write-only `ModelContext`.
    public func performWrite(_ block: (ModelContext) throws -> Void) throws {
        let context = ModelContext(userContainer)
        try block(context)
        if context.hasChanges {
            try context.save()
        }
    }

    // MARK: - Pack Management
    
    /// Installs a new data pack from a source folder URL.
    public func installPack(from downloadedURL: URL, allowsSave: Bool = false) {
        guard downloadedURL.startAccessingSecurityScopedResource() else {
             logger.error("Install failed: Could not gain security-scoped access to the pack folder.")
             return
        }
        defer { downloadedURL.stopAccessingSecurityScopedResource() }

        let tempInstallDir = storage.quarantineDirectoryURL.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempInstallDir) }

        do {
            try FileManager.default.createDirectory(at: tempInstallDir, withIntermediateDirectories: true)
            
            let manifestURL = downloadedURL.appendingPathComponent("manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let metadata = try JSONDecoder().decode(Pack.self, from: manifestData)

            let sourceDBURL = downloadedURL.appendingPathComponent(metadata.databaseFileName)
            let tempStoreURL = tempInstallDir.appendingPathComponent(metadata.databaseFileName)
            
            try storage.copySQLiteSet(from: sourceDBURL, to: tempStoreURL)
            try manifestData.write(to: tempInstallDir.appendingPathComponent("manifest.json"), options: .atomic)
            try storage.validateStore(at: tempStoreURL)
            
            // Get a unique destination URL without creating the directory.
            let finalDestDir = try storage.getUniquePackDirectoryURL(for: metadata)
            
            // Rename the fully-formed temporary directory to its final destination.
            try FileManager.default.moveItem(at: tempInstallDir, to: finalDestDir)
            
            let newPack = InstalledPack(metadata: metadata, directoryURL: finalDestDir, allowsSave: allowsSave)
            registry.add(newPack)
            registry.save()
            
            reloadAllContainers()
            logger.info("Successfully installed pack: '\(metadata.title)'")
        } catch {
            logger.error("installPack failed: \(String(describing: error))")
        }
    }

    /// Removes a pack by its ID and deletes its directory from disk.
    public func removePack(id: UUID) async {
        guard let removedPack = registry.remove(id: id) else { return }
        registry.save()
        
        reloadAllContainers()

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(250))
        
        storage.removePackDirectory(at: removedPack.directoryURL)
        logger.info("Removed pack: '\(removedPack.metadata.title)'")
    }

    /// Creates and installs a new pack with mock data for testing or previews.
    public func addMockPack(title: String, readOnly: Bool = true, seed: (ModelContext) throws -> Void) {
        do {
            let metadata = Pack(id: UUID(), title: title, version: 1)
            let destDir = try storage.createUniquePackDirectory(for: metadata)
            let destStoreURL = destDir.appendingPathComponent(metadata.databaseFileName)
            
            let seedCfg = ModelConfiguration("seed-\(metadata.id.uuidString)", schema: schema, url: destStoreURL, allowsSave: true)
            let tempContainer = try ModelContainer(for: schema, configurations: [seedCfg])
            let ctx = ModelContext(tempContainer)
            try seed(ctx)
            try ctx.save()
            
            let manifestData = try JSONEncoder().encode(metadata)
            try manifestData.write(to: destDir.appendingPathComponent("manifest.json"))
            
            let installedPack = InstalledPack(metadata: metadata, directoryURL: destDir, allowsSave: !readOnly)
            registry.add(installedPack)
            registry.save()
            
            reloadAllContainers()
        } catch {
            logger.error("addMockPack failed: \(error)")
        }
    }
    
    // MARK: - Container Reloading
    
    private func reloadAllContainers() {
        do {
            let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            let result = try Self.buildAllContainers(
                schema: schema,
                mainStoreURL: mainStoreURL,
                mainStoreName: config.mainStoreName,
                packs: registry.packs
            )
            userContainer = result.user
            packsContainer = result.packs
            mainContainer = result.main
            if !result.excluded.isEmpty {
                let titles = result.excluded.map { $0.metadata.title }.joined(separator: ", ")
                logger.warning("Excluded packs on reload: \(titles)")
            }
        } catch {
            logger.critical("CRITICAL: reloadAllContainers failed: \(error.localizedDescription). App may be in an inconsistent state.")
        }
    }

    // MARK: - Build Logic
    
    private static func buildAllContainers(schema: Schema, mainStoreURL: URL, mainStoreName: String, packs: [InstalledPack]) throws -> (main: ModelContainer, user: ModelContainer, packs: ModelContainer, excluded: [InstalledPack]) {
        let userConfig = ModelConfiguration(mainStoreName, schema: schema, url: mainStoreURL, allowsSave: true)
        
        var validPackConfigs: [ModelConfiguration] = []
        var excludedPacks: [InstalledPack] = []
        for p in packs {
            let cfg = ModelConfiguration(p.id.uuidString, schema: schema, url: p.storeURL, allowsSave: p.allowsSave)
            do {
                _ = try ModelContainer(for: schema, configurations: [cfg])
                validPackConfigs.append(cfg)
            } catch {
                logger.warning("Excluding pack '\(p.metadata.title)' due to load error: \(error.localizedDescription)")
                excludedPacks.append(p)
            }
        }
        
        let userContainer = try ModelContainer(for: schema, configurations: [userConfig])
        let packsContainer = try ModelContainer(for: schema, configurations: validPackConfigs)
        let mainContainer = try ModelContainer(for: schema, configurations: [userConfig] + validPackConfigs)
        
        return (mainContainer, userContainer, packsContainer, excludedPacks)
    }

    // MARK: - Utilities & Helpers
    
    /// Prepares a document for exporting an installed pack as a folder.
    public func packDirectoryDocument(for id: UUID) throws -> (PackDirectoryDocument, String) {
        guard let pack = registry.packs.first(where: { $0.id == id }) else {
            throw PackManagerError.buildError("No pack with id \(id.uuidString)")
        }
        return try storage.createExportDocument(from: pack.storeURL, metadata: pack.metadata)
    }

#if DEBUG
    /// (DEBUG-ONLY) Exports the main user store as a new, shareable pack.
    /// This is intended for developer use, allowing the creation of packs from user data.
    /// - Parameters:
    ///   - title: The title for the new pack.
    ///   - version: The version number for the new pack.
    /// - Returns: A tuple containing the exportable `PackDirectoryDocument` and a suggested filename.
    public func exportMainStoreAsPack(title: String, version: Int) throws -> (PackDirectoryDocument, String) {
        let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
        
        let newPackMetadata = Pack(
            id: UUID(),
            title: title,
            version: version,
            databaseFileName: mainStoreURL.lastPathComponent
        )
        
        logger.info("DEBUG: Exporting main store as pack '\(title)' v\(version)")
        return try storage.createExportDocument(from: mainStoreURL, metadata: newPackMetadata)
    }
#endif

    /// Retrieves the ModelConfiguration for a specific data source.
    public func configuration(for source: ContainerSource) -> ModelConfiguration? {
        switch source {
        case .mainStore:
            let storeURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            return ModelConfiguration(config.mainStoreName, schema: schema, url: storeURL, allowsSave: true)
            
        case .pack(let id):
            guard let pack = registry.packs.first(where: { $0.id == id }) else {
                logger.error("Configuration request failed: No pack found with ID \(id)")
                return nil
            }
            return ModelConfiguration(pack.id.uuidString, schema: schema, url: pack.storeURL, allowsSave: pack.allowsSave)
        }
    }
    
    static func primaryStoreURL(for name: String, rootURL: URL) -> URL {
        let storeDir = rootURL.appendingPathComponent(name, isDirectory: true)
        return storeDir.appendingPathComponent("\(name).store")
    }

    private static func ensureStoreExists(at storeURL: URL, schema: Schema) throws {
        let fm = FileManager.default
        let storeParentDir = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: storeParentDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: storeURL.path) else { return }
        
        let seedCfg = ModelConfiguration("seed-\(UUID().uuidString)", schema: schema, url: storeURL, allowsSave: true)
        let tempContainer = try ModelContainer(for: schema, configurations: [seedCfg])
        try ModelContext(tempContainer).save()
    }
}
