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

// Encapsulates the logic for managing the pending deletions file.
// Using a file-private enum with static methods allows us to call this logic
// during the main class's initialization phase without violating Swift's rules.
fileprivate enum PendingDeletionsManager {
    static func fileURL(storage: PackStorageManager) -> URL {
        storage.packsDirectoryURL.appendingPathComponent("pending_deletions.json")
    }

    static func load(storage: PackStorageManager) -> [UUID] {
        let url = fileURL(storage: storage)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([UUID].self, from: data)
        else {
            return []
        }
        return ids
    }

    static func save(_ ids: [UUID], storage: PackStorageManager) {
        let url = fileURL(storage: storage)
        do {
            let data = try JSONEncoder().encode(ids)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save pending deletions file: \(error)")
        }
    }
    
    static func add(id: UUID, storage: PackStorageManager) {
        var ids = load(storage: storage)
        if !ids.contains(id) {
            ids.append(id)
            save(ids, storage: storage)
        }
    }

    static func cleanup(storage: PackStorageManager) {
        let pendingIDs = Set(load(storage: storage))
        guard !pendingIDs.isEmpty else { return }
        
        let fm = FileManager.default
        guard let allPackDirs = try? fm.contentsOfDirectory(at: storage.packsDirectoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return
        }
        
        for dirURL in allPackDirs {
            guard dirURL.hasDirectoryPath else { continue }
            
            let manifestURL = dirURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let metadata = try? JSONDecoder().decode(Pack.self, from: data) else {
                continue
            }
            
            if pendingIDs.contains(metadata.id) {
                storage.removePackDirectory(at: dirURL)
                logger.info("Cleaned up pack '\(metadata.title)' marked for deletion.")
            }
        }
        
        // Clear the pending deletions list after cleanup
        save([], storage: storage)
    }
}


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
    
    private(set) var currentUserStoreURL: URL
    
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
    private let modelTypes: [any PersistentModel.Type]
    private let storage: PackStorageManager
    private let registry: PackRegistry
    
    // MARK: - Initialization
    
    public init(for models: [any PersistentModel.Type], config: SwiftDataPackManagerConfiguration) throws {
        self.config = config
        self.schema = Schema(models)
        self.modelTypes = models
        
        // 1. Establish Root Directory
        let fm = FileManager.default
        guard let appIdentifier = Bundle.main.bundleIdentifier ?? Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String else {
            throw PackManagerError.initializationFailed(reason: "Cannot determine app bundle identifier.")
        }
        
        do {
            let appSupportURL = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let baseAppURL = appSupportURL.appendingPathComponent(appIdentifier, isDirectory: true)
            self.rootURL = baseAppURL.appendingPathComponent("SwiftDataPacks", isDirectory: true)
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            logger.info("SwiftDataPacks root URL: \(self.rootURL.path)")
            
            // 2. Initialize Storage Manager
            self.storage = PackStorageManager(rootURL: rootURL, schema: schema)
            
            // 3. Perform cleanup of packs pending deletion BEFORE loading registry and containers
            PendingDeletionsManager.cleanup(storage: self.storage)
            
            // 4. Initialize Registry
            let registryURL = self.storage.packsDirectoryURL.appendingPathComponent("installed_packs.json")
            self.registry = PackRegistry(storeURL: registryURL)
            
            // 5. Bootstrap File System & Build Containers
            try self.storage.bootstrap()
            let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, storage: self.storage)
            self.currentUserStoreURL = mainStoreURL
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
        
        // 6. Perform initial cleanup of the staging directory
        storage.emptyStagingDirectory()
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
    
    /// Installs a new data pack from a source folder URL, or updates an existing one.
    public func installPack(from downloadedURL: URL, allowsSave: Bool = false) {
        guard downloadedURL.startAccessingSecurityScopedResource() else {
            logger.error("Install failed: Could not gain security-scoped access to the pack folder.")
            return
        }
        defer { downloadedURL.stopAccessingSecurityScopedResource() }
        
        let tempInstallDir = storage.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)
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
            
            // ** ID Collision Check **
            try checkForIDCollisions(with: tempStoreURL)
            
            // Check if a pack with the same ID already exists to perform an update.
            if let existingPack = registry.packs.first(where: { $0.id == metadata.id }) {
                // UPDATE an existing pack
                guard metadata.version > existingPack.metadata.version else {
                    logger.warning("Skipping install: Pack '\(metadata.title)' version (\(metadata.version)) is not newer than installed version (\(existingPack.metadata.version)).")
                    return
                }
                
                logger.info("Updating pack '\(metadata.title)' from version \(existingPack.metadata.version) to \(metadata.version)...")
                
                let finalDestDir = existingPack.directoryURL
                let backupDir = storage.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)

                do {
                    // Move the old directory to a temporary backup location.
                    try FileManager.default.moveItem(at: finalDestDir, to: backupDir)
                    
                    // Move the new directory into its final place.
                    try FileManager.default.moveItem(at: tempInstallDir, to: finalDestDir)
                    
                    // Clean up the backup.
                    try? FileManager.default.removeItem(at: backupDir)
                    
                } catch {
                    // If the move fails, try to restore the backup.
                    try? FileManager.default.moveItem(at: backupDir, to: finalDestDir)
                    throw error // Re-throw the error to be caught by the outer handler.
                }
                
                // Update the registry with the new metadata, preserving the existing directory URL and allowsSave setting.
                let updatedPack = InstalledPack(metadata: metadata, directoryURL: finalDestDir, allowsSave: existingPack.allowsSave)
                registry.add(updatedPack)
                registry.save()
                
                reloadAllContainers()
                logger.info("Successfully updated pack: '\(metadata.title)'")
                
            } else {
                // INSTALL a new pack
                // Get a unique destination URL without creating the directory.
                let finalDestDir = try storage.getUniquePackDirectoryURL(for: metadata)
                
                // Rename the fully-formed temporary directory to its final destination.
                try FileManager.default.moveItem(at: tempInstallDir, to: finalDestDir)
                
                let newPack = InstalledPack(metadata: metadata, directoryURL: finalDestDir, allowsSave: allowsSave)
                registry.add(newPack)
                registry.save()
                
                reloadAllContainers()
                logger.info("Successfully installed pack: '\(metadata.title)'")
            }
        } catch {
            logger.error("installPack failed: \(String(describing: error))")
        }
    }
    
    /// Marks a pack for deletion. The pack's directory will be removed on the next app launch.
    public func removePack(id: UUID) {
        guard let removed = registry.remove(id: id) else { return }
        registry.save()
        
        // Add the pack to the pending deletions list for cleanup on next launch.
        // DO NOT touch the files on disk during this operation.
        PendingDeletionsManager.add(id: id, storage: self.storage)
        
        // Build configs that exclude the removed pack
        let userURL = Self.primaryStoreURL(for: config.mainStoreName, storage: self.storage)
        let newUserCfg = ModelConfiguration(config.mainStoreName, schema: schema, url: userURL, allowsSave: true)
        
        let newPackCfgs = registry.packs.map {
            ModelConfiguration($0.id.uuidString, schema: schema, url: $0.storeURL, allowsSave: $0.allowsSave)
        }
        
        // Hot-swap the containers.
        hotSwapContainers(newUserConfig: newUserCfg, newPackConfigs: newPackCfgs)
        logger.info("Marked pack '\(removed.metadata.title)' for deletion on next app launch.")
    }
    
    @MainActor
    private func hotSwapContainers(
        newUserConfig: ModelConfiguration,
        newPackConfigs: [ModelConfiguration],
        afterSwap fileOperation: (() -> Void)? = nil
    ) {
        do {
            // Prebuild
            let newUser = try ModelContainer(for: schema, configurations: [newUserConfig])
            let newPacks = try ModelContainer(for: schema, configurations: newPackConfigs)
            let newMain  = try ModelContainer(for: schema, configurations: [newUserConfig] + newPackConfigs)
            
            // Single atomic swap without animation; never point the UI to an empty/in-memory container
            withoutAnimation {
                self.userContainer = newUser
                self.packsContainer = newPacks
                self.mainContainer = newMain
            }
            
            // The file operation can now run immediately. Callers must ensure it's safe.
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
        let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, storage: self.storage)
        
        let newPackMetadata = Pack(
            id: UUID(),
            title: title,
            version: version,
            databaseFileName: mainStoreURL.lastPathComponent
        )
        
        logger.info("DEBUG: Exporting main store as pack '\(title)' v\(version)")
        return try storage.createExportDocument(from: mainStoreURL, metadata: newPackMetadata)
    }
    
    /// (DEBUG-ONLY) Deletes the entire user data store from disk and reloads the containers.
    /// The old store is moved to the staging directory for cleanup on the next app launch.
    public func DEBUG_deleteUserContainer() {
        logger.warning("DEBUG: Deleting user container...")
        
        let userStoreParentDir = storage.mainStoreDirectoryURL
        
        // Define a destination for the old store in the staging area.
        let backupDir = storage.stagingDirectoryURL.appendingPathComponent("user-db-backup-\(UUID().uuidString)")
        
        do {
            // 1. Move the entire user store directory to the staging area for later deletion.
            if FileManager.default.fileExists(atPath: userStoreParentDir.path) {
                try FileManager.default.moveItem(at: userStoreParentDir, to: backupDir)
            }
            
            // 2. Create a new, empty store at the original location.
            let canonicalUserStoreURL = Self.primaryStoreURL(for: config.mainStoreName, storage: self.storage)
            try Self.ensureStoreExists(at: canonicalUserStoreURL, schema: schema)
            
            // 3. Hot-swap to the new, empty store.
            let newUserCfg = ModelConfiguration(config.mainStoreName, schema: schema, url: canonicalUserStoreURL, allowsSave: true)
            let packCfgs = registry.packs.map {
                ModelConfiguration($0.id.uuidString, schema: schema, url: $0.storeURL, allowsSave: $0.allowsSave)
            }
            
            hotSwapContainers(newUserConfig: newUserCfg, newPackConfigs: packCfgs)
            
            logger.info("DEBUG: User store has been reset. Old data will be purged on next launch.")
            
        } catch {
            logger.error("DEBUG: delete user container failed: \(error.localizedDescription)")
            // Attempt to restore the backup if something went wrong.
            if !FileManager.default.fileExists(atPath: userStoreParentDir.path) {
                try? FileManager.default.moveItem(at: backupDir, to: userStoreParentDir)
            }
        }
    }
#endif
    
    // MARK: - Container Reloading
    
    // reloadAllContainers is now simpler and just handles the build logic.
    private func reloadAllContainers() {
        do {
            let result = try Self.buildAllContainers(
                schema: schema,
                mainStoreURL: currentUserStoreURL,
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
    /// Retrieves the ModelConfiguration for a specific data source.
    public func configuration(for source: ContainerSource) -> ModelConfiguration? {
        switch source {
        case .mainStore:
            return ModelConfiguration(config.mainStoreName, schema: schema, url: currentUserStoreURL, allowsSave: true)
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
        
        // 1. Get all persistent IDs from the user's store.
        let userModelIDs = try getAllPersistentIDs(from: userContainer)
        guard !userModelIDs.isEmpty else {
            logger.info("User library is empty, no collisions possible. Skipping check.")
            return
        }
        
        // 2. Load the incoming store into a temporary, read-only container.
        let incomingConfig = ModelConfiguration("collision-check-\(UUID().uuidString)", schema: schema, url: incomingStoreURL, allowsSave: false)
        let incomingContainer = try ModelContainer(for: schema, configurations: [incomingConfig])
        
        // 3. Get all IDs from the incoming store.
        let incomingModelIDs = try getAllPersistentIDs(from: incomingContainer)
        
        // 4. Check if the sets are disjoint. If not, an ID exists in both.
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
            // Call the static helper on the concrete model type.
            let ids = try modelType._fetchAllIDs(from: context)
            allIDs.formUnion(ids)
        }
        return allIDs
    }
}

// MARK: - PersistentModel Helper Extension
fileprivate extension PersistentModel {
    /// Fetches all persistent IDs for the conforming type (`Self`) from a given model context.
    /// This works because `Self` is the concrete `PersistentModel` type at the point of execution.
    static func _fetchAllIDs(from context: ModelContext) throws -> [PersistentIdentifier] {
        var ids: [PersistentIdentifier] = []
        let batchSize = 500 // A reasonable batch size for memory efficiency.
        
        // Use the efficient enumerate method to process models in batches without
        // holding them all in memory.
        let descriptor = FetchDescriptor<Self>()
        try context.enumerate(descriptor, batchSize: batchSize) { model in
            ids.append(model.persistentModelID)
        }
        
        return ids
    }
}
