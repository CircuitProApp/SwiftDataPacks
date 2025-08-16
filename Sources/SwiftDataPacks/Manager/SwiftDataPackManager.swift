import Foundation
import SwiftUI
import SwiftData
import Observation

@Observable
@MainActor
public final class SwiftDataPackManager {
    // MARK: - Public Properties
    
    /// The main, multi-store ModelContainer managed by the pack system.
    private(set) var container: ModelContainer

    /// Provides public, read-only access to the list of installed packs from the registry.
    public var installedPacks: [InstalledPack] {
        registry.packs
    }

    // MARK: - Core State & Delegates
    
    // Core configuration
    let schema: Schema
    let rootURL: URL
    let config: SwiftDataPackManagerConfiguration

    // Delegated responsibilities
    private let storage: PackStorageManager
    private let registry: PackRegistry

    // In-memory caches for single-pack containers
    private var packContainerCache: [String: ModelContainer] = [:]

    // MARK: - Initialization

    init(for models: [any PersistentModel.Type], config: SwiftDataPackManagerConfiguration) {
           self.config = config
           self.schema = Schema(models)

           // 1. Establish the root directory for all operations
           let fm = FileManager.default
           guard let appIdentifier = Bundle.main.bundleIdentifier ?? Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String else {
               fatalError("Cannot determine app bundle identifier.")
           }
           
           do {
               let appSupportURL = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
               let root = appSupportURL.appendingPathComponent(appIdentifier, isDirectory: true)
               try fm.createDirectory(at: root, withIntermediateDirectories: true)
               self.rootURL = root
               print("SwiftDataPackManager root URL: \(root.path)")

               // 2. Initialize the delegated managers
               self.storage = PackStorageManager(rootURL: root, schema: schema)
               
               // --- CHANGE HERE ---
               // The registry's storeURL now points inside the Packs directory.
               // We get this path directly from the storage manager's public property.
               let registryURL = self.storage.packsDirectoryURL.appendingPathComponent("installed_packs.json")
               self.registry = PackRegistry(storeURL: registryURL)
               // --- END CHANGE ---
               
               // 3. Ensure all necessary file system structures exist
               // This now also ensures the parent directory for "installed_packs.json" exists.
               try self.storage.bootstrap()
               let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: root)
               try Self.ensureStoreExists(at: mainStoreURL, schema: schema)

               // 4. Build the main container using the loaded packs from the registry
               let result = try Self.buildContainerBestEffort(
                   schema: schema,
                   mainStoreURL: mainStoreURL,
                   mainStoreName: config.mainStoreName,
                   packs: registry.packs
               )
               self.container = result.container
               if !result.excluded.isEmpty {
                   let titles = result.excluded.map { $0.metadata.title }.joined(separator: ", ")
                   print("Excluded packs at launch: \(titles)")
               }
           } catch {
                fatalError("SwiftDataPackManager initialization failed: \(error)")
           }

           // 5. Perform initial cleanup
           storage.emptyQuarantine()
       }
    /// Rebuilds the main ModelContainer from the current list of installed packs.
    func reloadContainer() {
        do {
            let mainStoreURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            let result = try Self.buildContainerBestEffort(
                schema: schema,
                mainStoreURL: mainStoreURL,
                mainStoreName: config.mainStoreName,
                packs: registry.packs
            )
            container = result.container
            if !result.excluded.isEmpty {
                let titles = result.excluded.map { $0.metadata.title }.joined(separator: ", ")
                print("Excluded packs on reload: \(titles)")
            }
        } catch {
            print("reloadContainer failed: \(String(describing: error)) — falling back to a single default store.")
            let fallbackURL = Self.primaryStoreURL(for: "default", rootURL: rootURL)
            let fallbackConfig = ModelConfiguration("default", schema: schema, url: fallbackURL, allowsSave: true)
            container = try! ModelContainer(for: schema, configurations: [fallbackConfig])
        }
        invalidateAllCaches()
    }
}

// MARK: - Errors
struct BuildError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Build / Bootstrap Logic
extension SwiftDataPackManager {
    static func primaryStoreURL(for name: String, rootURL: URL) -> URL {
        let storeDir = rootURL.appendingPathComponent(name, isDirectory: true)
        return storeDir.appendingPathComponent("\(name).store")
    }

    private static func ensureStoreExists(at storeURL: URL, schema: Schema) throws {
        let fm = FileManager.default
        let storeParentDir = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: storeParentDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: storeURL.path) else { return }
        
        // Create an empty store file by initializing a temporary container and saving.
        let seedCfg = ModelConfiguration("seed-\(UUID().uuidString)", schema: schema, url: storeURL, allowsSave: true)
        let tempContainer = try ModelContainer(for: schema, configurations: [seedCfg])
        try ModelContext(tempContainer).save()
    }

    static func buildContainerBestEffort(schema: Schema, mainStoreURL: URL, mainStoreName: String, packs: [InstalledPack]) throws -> (container: ModelContainer, excluded: [InstalledPack]) {
        var validConfigurations: [ModelConfiguration] = []

        // Configure the main, writable store
        let mainConfig = ModelConfiguration(mainStoreName, schema: schema, url: mainStoreURL, allowsSave: true)
        validConfigurations.append(mainConfig)

        // Add a configuration for each valid installed pack
        var excludedPacks: [InstalledPack] = []
        for p in packs {
            let cfg = ModelConfiguration(p.id.uuidString, schema: schema, url: p.storeURL, allowsSave: p.allowsSave)
            do {
                _ = try ModelContainer(for: schema, configurations: [cfg])
                validConfigurations.append(cfg)
            } catch {
                print("Excluding pack '\(p.metadata.title)' due to load error: \(error.localizedDescription)")
                excludedPacks.append(p)
            }
        }
        
        let container = try ModelContainer(for: schema, configurations: validConfigurations)
        return (container, excludedPacks)
    }
}

// MARK: - Public Pack Management API
extension SwiftDataPackManager {

    /// Installs a new data pack from a source folder URL.
    public func installPack(from downloadedURL: URL, allowsSave: Bool = false) {
        guard downloadedURL.startAccessingSecurityScopedResource() else {
             print("Install failed: Could not gain security-scoped access to the pack folder.")
             return
        }
        defer { downloadedURL.stopAccessingSecurityScopedResource() }

        do {
            // 1. Decode metadata
            let manifestURL = downloadedURL.appendingPathComponent("manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let metadata = try JSONDecoder().decode(Pack.self, from: manifestData)

            // 2. Delegate all file operations to the storage manager
            let destDir = try storage.createUniquePackDirectory(for: metadata)
            let sourceDBURL = downloadedURL.appendingPathComponent(metadata.databaseFileName)
            let destStoreURL = destDir.appendingPathComponent(metadata.databaseFileName)
            
            try storage.copySQLiteSet(from: sourceDBURL, to: destStoreURL)
            try manifestData.write(to: destDir.appendingPathComponent("manifest.json"), options: .atomic)
             try storage.validateStore(at: destStoreURL)
            
            // 3. Delegate registry update
            let newPack = InstalledPack(metadata: metadata, directoryURL: destDir, allowsSave: allowsSave)
            registry.add(newPack)
            registry.save()
            
            // 4. Reload the container to include the new pack
            reloadContainer()
            print("Successfully installed pack: '\(metadata.title)'")
        } catch {
            print("installPack failed: \(String(describing: error))")
            // Future enhancement: Clean up `destDir` on failure.
        }
    }

    /// Removes a pack by its ID and deletes its directory from disk.
    public func removePack(id: UUID) async {
        // 1. Delegate registry update
        guard let removedPack = registry.remove(id: id) else { return }
        registry.save()
        
        // 2. Reload container immediately to remove the pack from the app's view
        reloadContainer()

        // 3. Defer directory deletion to avoid race conditions with SwiftData
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(500))
        
        storage.removePackDirectory(at: removedPack.directoryURL)
        print("Removed pack: '\(removedPack.metadata.title)'")
    }

    /// Creates a temporary, in-memory ModelContainer for a single pack.
    public func containerForPack(id: UUID, readOnly: Bool = true) -> ModelContainer? {
        let cacheKey = id.uuidString
        if let cached = packContainerCache[cacheKey] { return cached }

        guard let pack = registry.packs.first(where: { $0.id == id }) else {
            print("containerForPack: no pack found with id \(id)")
            return nil
        }
        
        let allowsSave = readOnly ? false : pack.allowsSave
        let cfg = ModelConfiguration(pack.id.uuidString, schema: schema, url: pack.storeURL, allowsSave: allowsSave)
        
        do {
            let singleContainer = try ModelContainer(for: schema, configurations: [cfg])
            packContainerCache[cacheKey] = singleContainer
            return singleContainer
        } catch {
            print("containerForPack(\(id)) failed to open \(pack.storeURL.path): \(String(describing: error))")
            return nil
        }
    }
    
    /// Clears any cached single-pack containers.
    public func invalidateAllCaches() {
        packContainerCache.removeAll()
    }
}

// MARK: - Utilities (Testing & Export)
extension SwiftDataPackManager {

    /// Creates and installs a new pack with mock data for testing or previews.
    public func addMockPack(title: String, readOnly: Bool = true, seed: (ModelContext) throws -> Void) {
        do {
            // 1. Create metadata and use the storage manager to allocate a directory
            let metadata = Pack(id: UUID(), title: title, version: 1)
            let destDir = try storage.createUniquePackDirectory(for: metadata)
            let destStoreURL = destDir.appendingPathComponent(metadata.databaseFileName)
            
            // 2. Seed the database file at the destination
            let seedCfg = ModelConfiguration("seed-\(metadata.id.uuidString)", schema: schema, url: destStoreURL, allowsSave: true)
            let tempContainer = try ModelContainer(for: schema, configurations: [seedCfg])
            let ctx = ModelContext(tempContainer)
            try seed(ctx)
            try ctx.save()
            
            // 3. Write manifest and register the new pack
            let manifestData = try JSONEncoder().encode(metadata)
            try manifestData.write(to: destDir.appendingPathComponent("manifest.json"))
            
            let installedPack = InstalledPack(metadata: metadata, directoryURL: destDir, allowsSave: !readOnly)
            registry.add(installedPack)
            registry.save()
            
            reloadContainer()
        } catch {
            print("addMockPack failed: \(error)")
        }
    }

    /// Prepares a document for exporting an installed pack as a folder.
    public func packDirectoryDocument(for id: UUID) throws -> (PackDirectoryDocument, String) {
        guard let pack = registry.packs.first(where: { $0.id == id }) else {
            throw BuildError(message: "No pack with id \(id.uuidString)")
        }
        
        let fm = FileManager.default
        let storeURL = pack.storeURL
        var files: [String: Data] = [pack.metadata.databaseFileName: try Data(contentsOf: storeURL)]
        
        // Include -wal and -shm files if they exist
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        if fm.fileExists(atPath: walURL.path) {
            files[walURL.lastPathComponent] = try Data(contentsOf: walURL)
        }
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        if fm.fileExists(atPath: shmURL.path) {
            files[shmURL.lastPathComponent] = try Data(contentsOf: shmURL)
        }

        let doc = PackDirectoryDocument(manifest: pack.metadata, databaseFiles: files)
        let suggestedName = pack.metadata.title.replacingOccurrences(of: "/", with: "-") + ".pack"
        
        return (doc, suggestedName)
    }
}

// MARK: - Model Configuration Access
extension SwiftDataPackManager {

    /// Retrieves the ModelConfiguration for a specific data source (main store or a pack).
    public func configuration(for source: ContainerSource) -> ModelConfiguration? {
        switch source {
        case .mainStore:
            let storeURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            return ModelConfiguration(config.mainStoreName, schema: schema, url: storeURL, allowsSave: true)
            
        case .pack(let id):
            guard let pack = registry.packs.first(where: { $0.id == id }) else {
                print("Configuration request failed: No pack found with ID \(id)")
                return nil
            }
            return ModelConfiguration(pack.id.uuidString, schema: schema, url: pack.storeURL, allowsSave: pack.allowsSave)
        }
    }
}
