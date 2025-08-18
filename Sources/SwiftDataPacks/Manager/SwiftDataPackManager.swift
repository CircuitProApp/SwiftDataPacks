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
    // MARK: - Constants
    private static let mainStoreName = "database"
    
    // MARK: - Public Containers
    
    /// The main, composite container of all stores for unified display.
    private(set) var mainContainer: ModelContainer
    
    private(set) var currentUserStoreURL: URL
    
    // MARK: - Public State
    
    public var installedPacks: [InstalledPack] {
        registry.packs
    }
    
    public var packsDirectoryURL: URL {
        storage.packsDirectoryURL
    }
    
    // MARK: - Core State & Delegates
    
    let schema: Schema
    let rootURL: URL
    private let modelTypes: [any PersistentModel.Type]
    private let storage: PackStorageManager
    private let registry: PackRegistry
    
    // MARK: - Static Helpers
    
    /// Determines the root directory for all SwiftDataPacks content.
    static func getRootURL() -> URL? {
        let fm = FileManager.default
        guard let appIdentifier = Bundle.main.bundleIdentifier ?? Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String else {
            logger.error("Cannot determine app bundle identifier.")
            return nil
        }
        
        do {
            let appSupportURL = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let baseAppURL = appSupportURL.appendingPathComponent(appIdentifier, isDirectory: true)
            return baseAppURL.appendingPathComponent("SwiftDataPacks", isDirectory: true)
        } catch {
            logger.error("Could not create application support directory URL: \(error)")
            return nil
        }
    }
    
    // MARK: - Initialization
    
    public init(for models: [any PersistentModel.Type]) throws {
        // Ensure the lifecycle observer is initialized to handle one-time launch tasks.
        _ = LifecycleObserver.shared
        
        self.schema = Schema(models)
        self.modelTypes = models
        
        let fm = FileManager.default
        guard let rootURL = Self.getRootURL() else {
            throw PackManagerError.initializationFailed(reason: "Cannot determine SwiftDataPacks root URL.")
        }
        self.rootURL = rootURL

        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            logger.info("SwiftDataPacks root URL: \(self.rootURL.path)")
            
            self.storage = PackStorageManager(rootURL: rootURL, schema: schema)
            
            let registryURL = self.storage.packsDirectoryURL.appendingPathComponent("installed_packs.json")
            self.registry = PackRegistry(storeURL: registryURL)
            
            try self.storage.bootstrap()
            let mainStoreURL = Self.primaryStoreURL(for: Self.mainStoreName, storage: self.storage)
            self.currentUserStoreURL = mainStoreURL
            try Self.ensureStoreExists(at: mainStoreURL, schema: schema)
            
            self.mainContainer = try Self.buildMainContainer(
                schema: schema,
                mainStoreURL: mainStoreURL,
                mainStoreName: Self.mainStoreName,
                packs: registry.packs
            )

        } catch {
            throw PackManagerError.initializationFailed(reason: error.localizedDescription)
        }
        
        storage.emptyStagingDirectory()
    }
    
    // MARK: - Public Write API
    
    public func performWrite(_ block: (ModelContext) throws -> Void) throws {
        guard let userConfig = configuration(for: .mainStore) else {
            throw PackManagerError.buildError("Could not create configuration for user store.")
        }
        
        let writeContainer = try ModelContainer(for: schema, configurations: [userConfig])
        let context = ModelContext(writeContainer)
        try block(context)
        if context.hasChanges {
            try context.save()
        }
    }
    
    // MARK: - Pack Management
    
    public func installPack(from downloadedURL: URL, allowsSave: Bool = false) {
        // Attempt to gain security-scoped access. This will return true for external
        // files and false for internal files.
        let needsSecurityScopedAccess = downloadedURL.startAccessingSecurityScopedResource()
        
        defer {
            // Only stop accessing if we successfully started.
            if needsSecurityScopedAccess {
                downloadedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempInstallDir = storage.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempInstallDir) }
        
        do {
            // Create the temporary directory.
            try FileManager.default.createDirectory(at: tempInstallDir, withIntermediateDirectories: true)
            
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(at: downloadedURL, includingPropertiesForKeys: nil)
            for itemURL in contents {
                try fileManager.copyItem(at: itemURL, to: tempInstallDir.appendingPathComponent(itemURL.lastPathComponent))
            }
            
            // Now, all subsequent operations will safely use the files inside tempInstallDir.
            let manifestURL = tempInstallDir.appendingPathComponent("manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let metadata = try JSONDecoder().decode(Pack.self, from: manifestData)
            
            let storeURL = tempInstallDir.appendingPathComponent(metadata.databaseFileName)
            
            try storage.validateStore(at: storeURL)
            try checkForIDCollisions(with: storeURL)
            
            if let existingPack = registry.packs.first(where: { $0.id == metadata.id }) {
                guard metadata.version > existingPack.metadata.version else {
                    logger.warning("Skipping install: Pack '\(metadata.title)' version (\(metadata.version)) is not newer than installed version (\(existingPack.metadata.version)).")
                    return
                }
                
                logger.info("Updating pack '\(metadata.title)' from version \(existingPack.metadata.version) to \(metadata.version)...")
                let finalDestDir = existingPack.directoryURL
                let backupDir = storage.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)

                do {
                    try fileManager.moveItem(at: finalDestDir, to: backupDir)
                    try fileManager.moveItem(at: tempInstallDir, to: finalDestDir)
                    try? fileManager.removeItem(at: backupDir)
                } catch {
                    // If the update fails, try to restore the backup.
                    try? fileManager.moveItem(at: backupDir, to: finalDestDir)
                    throw error
                }
                
                let updatedPack = InstalledPack(metadata: metadata, directoryURL: finalDestDir, allowsSave: existingPack.allowsSave)
                registry.add(updatedPack)
                
            } else {
                let finalDestDir = try storage.getUniquePackDirectoryURL(for: metadata)
                try fileManager.moveItem(at: tempInstallDir, to: finalDestDir)
                
                let newPack = InstalledPack(metadata: metadata, directoryURL: finalDestDir, allowsSave: allowsSave)
                registry.add(newPack)
            }
            
            // Save changes to the registry and reload containers
            registry.save()
            reloadAllContainers()
            logger.info("Successfully installed or updated pack: '\(metadata.title)'")
            
        } catch {
            logger.error("installPack failed: \(String(describing: error))")
        }
    }
    
    public func removePack(id: UUID) {
        guard let removed = registry.remove(id: id) else { return }
        registry.save()
        
        PendingDeletionsManager.add(id: id, storage: self.storage)
        
        let userURL = Self.primaryStoreURL(for: Self.mainStoreName, storage: self.storage)
        let newUserCfg = ModelConfiguration(Self.mainStoreName, schema: schema, url: userURL, allowsSave: true)
        
        let newPackCfgs = registry.packs.map {
            ModelConfiguration($0.id.uuidString, schema: schema, url: $0.storeURL, allowsSave: $0.allowsSave)
        }
        
        hotSwapContainers(newUserConfig: newUserCfg, newPackConfigs: newPackCfgs)
        logger.info("Marked pack '\(removed.metadata.title)' for deletion on next app launch.")
    }
    
    @MainActor
    private func hotSwapContainers(newUserConfig: ModelConfiguration, newPackConfigs: [ModelConfiguration], afterSwap fileOperation: (() -> Void)? = nil) {
        do {
            let newMain  = try ModelContainer(for: schema, configurations: [newUserConfig] + newPackConfigs)
            
            withoutAnimation {
                self.mainContainer = newMain
            }
            
            fileOperation?()
        } catch {
            logger.critical("Hot swap failed: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func withoutAnimation(_ body: () -> Void) {
        #if canImport(UIKit)
        UIView.performWithoutAnimation(body)
        #elseif canImport(AppKit)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            body()
        }
        #else
        body()
        #endif
    }
    
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
    
    // MARK: - Build Logic
    
    private static func buildMainContainer(schema: Schema, mainStoreURL: URL, mainStoreName: String, packs: [InstalledPack]) throws -> ModelContainer {
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
        
        let mainContainer = try ModelContainer(for: schema, configurations: [userConfig] + validPackConfigs)
        
        if !excludedPacks.isEmpty {
            let titles = excludedPacks.map { $0.metadata.title }.joined(separator: ", ")
            logger.warning("Excluded packs during container build: \(titles)")
        }
        
        return mainContainer
    }
    
    // MARK: - Utilities & Helpers
    
    public func packDirectoryDocument(for id: UUID) throws -> (PackDirectoryDocument, String) {
        guard let pack = registry.packs.first(where: { $0.id == id }) else {
            throw PackManagerError.buildError("No pack with id \(id.uuidString)")
        }
        return try storage.createExportDocument(from: pack.storeURL, metadata: pack.metadata)
    }
    
    #if DEBUG
    public func exportMainStoreAsPack(title: String, version: Int) throws -> (PackDirectoryDocument, String) {
        let mainStoreURL = Self.primaryStoreURL(for: Self.mainStoreName, storage: self.storage)
        
        let newPackMetadata = Pack(id: UUID(), title: title, version: version, databaseFileName: mainStoreURL.lastPathComponent)
        
        logger.info("DEBUG: Exporting main store as pack '\(title)' v\(version)")
        return try storage.createExportDocument(from: mainStoreURL, metadata: newPackMetadata)
    }
    
    public func DEBUG_deleteUserContainer() {
        logger.warning("DEBUG: Deleting user container...")
        
        let userStoreParentDir = storage.mainStoreDirectoryURL
        let backupDir = storage.stagingDirectoryURL.appendingPathComponent("user-db-backup-\(UUID().uuidString)")
        
        do {
            if FileManager.default.fileExists(atPath: userStoreParentDir.path) {
                try FileManager.default.moveItem(at: userStoreParentDir, to: backupDir)
            }
            
            let canonicalUserStoreURL = Self.primaryStoreURL(for: Self.mainStoreName, storage: self.storage)
            try Self.ensureStoreExists(at: canonicalUserStoreURL, schema: schema)
            
            let newUserCfg = ModelConfiguration(Self.mainStoreName, schema: schema, url: canonicalUserStoreURL, allowsSave: true)
            let packCfgs = registry.packs.map {
                ModelConfiguration($0.id.uuidString, schema: schema, url: $0.storeURL, allowsSave: $0.allowsSave)
            }
            
            hotSwapContainers(newUserConfig: newUserCfg, newPackConfigs: packCfgs)
            
            logger.info("DEBUG: User store has been reset. Old data will be purged on next launch.")
            
        } catch {
            logger.error("DEBUG: delete user container failed: \(error.localizedDescription)")
            if !FileManager.default.fileExists(atPath: userStoreParentDir.path) {
                try? FileManager.default.moveItem(at: backupDir, to: userStoreParentDir)
            }
        }
    }
    #endif
    
    // MARK: - Container Reloading
    
    private func reloadAllContainers() {
        do {
            self.mainContainer = try Self.buildMainContainer(
                schema: schema,
                mainStoreURL: currentUserStoreURL,
                mainStoreName: Self.mainStoreName,
                packs: registry.packs
            )
        } catch {
            logger.critical("CRITICAL: reloadAllContainers failed: \(error.localizedDescription). App may be in an inconsistent state.")
        }
    }
    
    public func configuration(for source: ContainerSource) -> ModelConfiguration? {
        switch source {
        case .mainStore:
            return ModelConfiguration(Self.mainStoreName, schema: schema, url: currentUserStoreURL, allowsSave: true)
        case .pack(let id):
            guard let pack = registry.packs.first(where: { $0.id == id }) else {
                logger.error("Configuration request failed: No pack found with ID \(id)")
                return nil
            }
            return ModelConfiguration(pack.id.uuidString, schema: schema, url: pack.storeURL, allowsSave: pack.allowsSave)
        }
    }
    
    static func primaryStoreURL(for name: String, storage: PackStorageManager) -> URL {
        let storeDir = storage.mainStoreDirectoryURL
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
    
    // MARK: - Private Helpers
    
    private func checkForIDCollisions(with incomingStoreURL: URL) throws {
        logger.info("Performing ID collision check...")
        
        guard let userConfig = configuration(for: .mainStore) else {
            throw PackManagerError.buildError("Could not create configuration for user store.")
        }
        let tempUserContainer = try ModelContainer(for: schema, configurations: [userConfig])
        let userModelIDs = try getAllPersistentIDs(from: tempUserContainer)
        
        guard !userModelIDs.isEmpty else {
            logger.info("User library is empty, no collisions possible. Skipping check.")
            return
        }
        
        let incomingConfig = ModelConfiguration("collision-check-\(UUID().uuidString)", schema: schema, url: incomingStoreURL, allowsSave: false)
        let incomingContainer = try ModelContainer(for: schema, configurations: [incomingConfig])
        let incomingModelIDs = try getAllPersistentIDs(from: incomingContainer)
        
        if !userModelIDs.isDisjoint(with: incomingModelIDs) {
            let collision = userModelIDs.first { incomingModelIDs.contains($0) }!
            logger.error("ID Collision Detected: An item with ID '\(String(describing: collision))' from entity '\(collision.entityName)' exists in both the user library and the pack.")
            throw PackManagerError.idCollisionDetected
        }
        
        logger.info("Collision check passed successfully.")
    }
    
    private func getAllPersistentIDs(from container: ModelContainer) throws -> Set<PersistentIdentifier> {
        var allIDs = Set<PersistentIdentifier>()
        let context = ModelContext(container)
        
        for modelType in modelTypes {
            let ids = try modelType._fetchAllIDs(from: context)
            allIDs.formUnion(ids)
        }
        return allIDs
    }
}

// MARK: - PersistentModel Helper Extension
fileprivate extension PersistentModel {
    static func _fetchAllIDs(from context: ModelContext) throws -> [PersistentIdentifier] {
        var ids: [PersistentIdentifier] = []
        let batchSize = 500
        
        let descriptor = FetchDescriptor<Self>()
        try context.enumerate(descriptor, batchSize: batchSize) { model in
            ids.append(model.persistentModelID)
        }
        
        return ids
    }
}
