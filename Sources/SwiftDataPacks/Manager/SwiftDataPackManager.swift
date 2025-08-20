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
    
    // MARK: - Public State
    
    /// The main, composite container of all stores for unified display.
    private(set) var mainContainer: ModelContainer
    
    public private(set) var currentUserStoreURL: URL
    
    public var installedPacks: [InstalledPack] {
        registry.packs
    }
    
    public var packsDirectoryURL: URL {
        storage.packsDirectoryURL
    }
    
    // MARK: - Core State & Delegates
    
    let schema: Schema
    let rootURL: URL
    private let storage: PackStorageManager
    private let registry: PackRegistry
    private let containerProvider: ModelContainerProvider
    
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
        _ = LifecycleObserver.shared
        
        self.schema = Schema(models)
        
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
            
            self.containerProvider = ModelContainerProvider(
                schema: self.schema,
                userStoreURL: mainStoreURL,
                mainStoreIdentifier: Self.mainStoreName
            )
            
            self.mainContainer = try self.containerProvider.buildMainContainer(for: registry.packs)

        } catch {
            throw PackManagerError.initializationFailed(reason: error.localizedDescription)
        }
        
        storage.emptyStagingDirectory()
    }
    
    // MARK: - Public Write API
    
    public func performWrite(_ block: (ModelContext) throws -> Void) throws {
        // Safely unwrap the optional configuration.
        guard let userConfig = configuration(for: .mainStore) else {
            throw PackManagerError.buildError("Could not create configuration for the main user store.")
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
        var stagedDir: URL?
        do {
            let (dir, metadata) = try _stageAndValidatePack(from: downloadedURL)
            stagedDir = dir
            defer { if let dir = stagedDir { try? FileManager.default.removeItem(at: dir) } }

            if let existing = registry.packs.first(where: { $0.id == metadata.id }) {
                throw PackManagerError.packAlreadyExists(id: existing.id, title: existing.metadata.title)
            }
            
            // Preflight: ensure the staged pack can be mounted alongside current stores.
            let stagedStoreURL = dir.appendingPathComponent(metadata.databaseFileName)
            guard canMountWithExistingStores(packStoreURL: stagedStoreURL, allowsSave: allowsSave) else {
                throw PackManagerError.installationFailed(reason: "Pack database is incompatible with the current stores.")
            }
            
            let finalDestDir = try storage.getUniquePackDirectoryURL(for: metadata)
            try FileManager.default.moveItem(at: dir, to: finalDestDir)
            stagedDir = nil

            let newPack = InstalledPack(metadata: metadata, directoryURL: finalDestDir, allowsSave: allowsSave)
            registry.add(newPack)
            registry.save()
            reloadAllContainers()
            
            logger.info("Successfully installed pack: '\(metadata.title)'")

        } catch {
            logger.error("installPack failed: \(String(describing: error))")
        }
    }

    public func updatePack(from downloadedURL: URL) {
        var stagedDir: URL?
        do {
            let (dir, newMetadata) = try _stageAndValidatePack(from: downloadedURL)
            stagedDir = dir
            defer { if let dir = stagedDir { try? FileManager.default.removeItem(at: dir) } }

            guard let existingPack = registry.packs.first(where: { $0.id == newMetadata.id }) else {
                throw PackManagerError.packToUpdateNotFound(id: newMetadata.id)
            }

            guard newMetadata.version > existingPack.metadata.version else {
                logger.warning("Skipping update: Pack '\(newMetadata.title)' version (\(newMetadata.version)) is not newer than installed version (\(existingPack.metadata.version)).")
                return
            }

            logger.info("Updating pack '\(newMetadata.title)' from version \(existingPack.metadata.version) to \(newMetadata.version)...")
            
            // Preflight: ensure the staged pack can be mounted alongside current stores.
            let stagedStoreURL = dir.appendingPathComponent(newMetadata.databaseFileName)
            guard canMountWithExistingStores(packStoreURL: stagedStoreURL, allowsSave: existingPack.allowsSave) else {
                throw PackManagerError.installationFailed(reason: "Pack database is incompatible with the current stores.")
            }
            
            let finalDestDir = existingPack.directoryURL
            let backupDir = storage.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)
            let fm = FileManager.default

            do {
                try fm.moveItem(at: finalDestDir, to: backupDir)
                try fm.moveItem(at: dir, to: finalDestDir)
                stagedDir = nil
                try? fm.removeItem(at: backupDir)
            } catch {
                if fm.fileExists(atPath: backupDir.path) && !fm.fileExists(atPath: finalDestDir.path) {
                    try? fm.moveItem(at: backupDir, to: finalDestDir)
                }
                throw error
            }

            let updatedPack = InstalledPack(metadata: newMetadata, directoryURL: finalDestDir, allowsSave: existingPack.allowsSave)
            registry.add(updatedPack)
            registry.save()
            reloadAllContainers()
            
            logger.info("Successfully updated pack: '\(newMetadata.title)'")

        } catch {
            logger.error("updatePack failed: \(String(describing: error))")
        }
    }
    
    public func removePack(id: UUID) {
        guard let removed = registry.remove(id: id) else { return }
        registry.save()
        
        PendingDeletionsManager.add(id: id, storage: self.storage)
        reloadAllContainers()
        
        logger.info("Marked pack '\(removed.metadata.title)' for deletion on next app launch.")
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
            
            reloadAllContainers()
            
            logger.info("DEBUG: User store has been reset. Old data will be purged on next launch.")
            
        } catch {
            logger.error("DEBUG: delete user container failed: \(error.localizedDescription)")
            if !FileManager.default.fileExists(atPath: userStoreParentDir.path) {
                try? FileManager.default.moveItem(at: backupDir, to: userStoreParentDir)
            }
        }
    }
    #endif
    
    // MARK: - Container Management & Reloading
    
    private func reloadAllContainers() {
        do {
            let newMainContainer = try self.containerProvider.buildMainContainer(for: registry.packs)
            withoutAnimation {
                self.mainContainer = newMainContainer
            }
        } catch {
            logger.critical("CRITICAL: reloadAllContainers failed: \(error.localizedDescription). App may be in an inconsistent state.")
        }
    }
    
    public func configuration(for source: ContainerSource) -> ModelConfiguration? {
        return containerProvider.configuration(for: source, allPacks: registry.packs)
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
    
    // MARK: - Private Helpers
    
    private func _stageAndValidatePack(from downloadedURL: URL) throws -> (stagedDir: URL, metadata: Pack) {
        let needsSecurityScopedAccess = downloadedURL.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScopedAccess {
                downloadedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempInstallDir = storage.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)
        
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: tempInstallDir, withIntermediateDirectories: true)
            
            let contents = try fm.contentsOfDirectory(at: downloadedURL, includingPropertiesForKeys: nil)
            for itemURL in contents {
                try fm.copyItem(at: itemURL, to: tempInstallDir.appendingPathComponent(itemURL.lastPathComponent))
            }
            
            let manifestURL = tempInstallDir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                throw PackManagerError.installationFailed(reason: "Manifest file (manifest.json) not found.")
            }
            
            let manifestData = try Data(contentsOf: manifestURL)
            let metadata = try JSONDecoder().decode(Pack.self, from: manifestData)
            
            let storeURL = tempInstallDir.appendingPathComponent(metadata.databaseFileName)
            guard fm.fileExists(atPath: storeURL.path) else {
                throw PackManagerError.installationFailed(reason: "Database file '\(metadata.databaseFileName)' not found in pack.")
            }
            
            // Ensure the staged store is at least individually openable.
            try storage.validateStore(at: storeURL)
            
            return (tempInstallDir, metadata)
            
        } catch {
            try? FileManager.default.removeItem(at: tempInstallDir)
            throw error
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
    
    /// Attempts to build a temporary container with the current user store + existing packs + a staged pack.
    /// Returns true if the composite container can be created (i.e., schemas are compatible).
    private func canMountWithExistingStores(packStoreURL: URL, allowsSave: Bool) -> Bool {
        guard let userCfg = configuration(for: .mainStore) else { return false }
        
        var configs: [ModelConfiguration] = [userCfg]
        configs.append(contentsOf: installedPacks.compactMap { configuration(for: .pack(id: $0.id)) })
        
        let preflightCfg = ModelConfiguration("preflight-\(UUID().uuidString)", schema: schema, url: packStoreURL, allowsSave: allowsSave)
        configs.append(preflightCfg)
        
        do {
            _ = try ModelContainer(for: schema, configurations: configs)
            return true
        } catch {
            logger.warning("Preflight mount failed: \(error.localizedDescription)")
            return false
        }
    }
}
