import Foundation
import SwiftUI
import SwiftData
import Observation

@Observable
@MainActor
public final class SwiftDataPackManager {
    // Shared main container used by most of the app
    private(set) var container: ModelContainer
    // Persisted list of installed packs
    private(set) var installedPacks: [PackDescriptor]

    // Cache of standalone single-pack containers
    private var packContainerCache: [String: ModelContainer] = [:]
    private var primaryStoreContainerCache: [String: ModelContainer] = [:]

    // Core configuration state
    let schema: Schema
    let rootURL: URL
    let config: SwiftDataPackManagerConfiguration

    init(for models: [any PersistentModel.Type], config: SwiftDataPackManagerConfiguration) {
        self.config = config
        // 1) Build schema
        let schema = Schema(models)
        self.schema = schema

        // 2) Prepare app-support paths based on bundle identifier (NEW, SIMPLIFIED LOGIC)
        let fm = FileManager.default
        
        // Use the app's bundle identifier for the support directory name. This is a standard macOS convention.
        // Fallback to a name from the info plist, or a hardcoded default if something is misconfigured.
        guard let appIdentifier = Bundle.main.bundleIdentifier ?? Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String else {
            fatalError("Cannot determine app bundle identifier. Please ensure it is set in your project's target settings.")
        }
        
        do {
            let appSupportURL = try fm.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
            
            // Create a single, conventionally-named root directory for all of the app's data.
            let root = appSupportURL.appendingPathComponent(appIdentifier, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            self.rootURL = root
            
            print("SwiftDataPackManager root directory: \(root.path)")

        } catch {
            fatalError("Could not create or access application support directory: \(error)")
        }

        // 3) Load pack descriptors
        let packs = PackStore.load()
        self.installedPacks = packs

        // 4) Ensure the main store exists on disk before loading
        do {
            let storeURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            print("Main store location: \(storeURL.path)")
            try Self.ensureStoreExists(at: storeURL, schema: schema)
        } catch {
            print("ensureStoreExists failed for main store: \(String(describing: error))")
        }

        // 5) Build the main container
        let built: ModelContainer
        do {
            let result = try SwiftDataPackManager.buildContainerBestEffort(
                schema: schema,
                rootURL: rootURL,
                mainStoreName: config.mainStoreName,
                packs: packs
            )
            built = result.container
            if !result.excluded.isEmpty {
                let titles = result.excluded.map { $0.title }.joined(separator: ", ")
                print("Excluded packs at launch: \(titles)")
            }
        } catch {
            // If the build fails, create a single, writable default store at the correct location.
            print("Main container build failed: \(String(describing: error)). Falling back to a single default store.")
            let fallbackURL = Self.primaryStoreURL(for: "Default", rootURL: rootURL)
            print("Fallback store location: \(fallbackURL.path)")
            let fallbackConfig = ModelConfiguration("default", schema: schema, url: fallbackURL, allowsSave: true)
            built = try! ModelContainer(for: schema, configurations: [fallbackConfig])
        }
        self.container = built
        
        // Optional: cleanup
        cleanupQuarantineOnLaunch()
    }

    // Public: Rebuild the main container (best-effort) and clear cache
    func reloadContainer() {
        do {
            let result = try Self.buildContainerBestEffort(
                schema: schema,
                rootURL: rootURL,
                mainStoreName: config.mainStoreName,
                packs: installedPacks
            )
            container = result.container
            if !result.excluded.isEmpty {
                let titles = result.excluded.map { $0.title }.joined(separator: ", ")
                print("Excluded packs on reload: \(titles)")
            }
        } catch {
            print("reloadContainer failed: \(String(describing: error)) — falling back to a single default store.")
            do {
                let fallbackURL = primaryStoreURL(for: "Default")
                print("Fallback store location on reload: \(fallbackURL.path)")
                let fallbackConfig = ModelConfiguration("default", schema: schema, url: fallbackURL, allowsSave: true)
                container = try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                assertionFailure("Fallback to default store container failed: \(error)")
            }
        }

        invalidateAllCaches()
    }
}


// MARK: - Errors

struct BuildError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Build / Bootstrap

extension SwiftDataPackManager {
    // UPDATED HELPER: Now points to a NESTED directory inside the root for better organization.
    private static func primaryStoreURL(for name: String, rootURL: URL) -> URL {
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
        
        let ctx = ModelContext(tempContainer)
        try ctx.save()
    }

    static func buildContainerBestEffort(schema: Schema,
                                         rootURL: URL,
                                         mainStoreName: String,
                                         packs: [PackDescriptor]) throws -> (container: ModelContainer, excluded: [PackDescriptor]) {
        var validConfigurations: [ModelConfiguration] = []

        // The main store is essential. If it fails, we throw.
        let mainStoreURL = Self.primaryStoreURL(for: mainStoreName, rootURL: rootURL)
        let mainConfig = ModelConfiguration(mainStoreName, schema: schema, url: mainStoreURL, allowsSave: true)
        do {
            _ = try ModelContainer(for: schema, configurations: [mainConfig])
            validConfigurations.append(mainConfig)
        } catch {
            print("Failed to open main store '\(mainStoreName)'.")
            throw error // Propagate to trigger fallback
        }
        
        var excludedPacks: [PackDescriptor] = []
        for p in packs {
            let cfg = ModelConfiguration(p.id, schema: schema, url: p.fileURL, allowsSave: p.allowsSave)
            do {
                _ = try ModelContainer(for: schema, configurations: [cfg])
                validConfigurations.append(cfg)
            } catch {
                excludedPacks.append(p)
            }
        }
        
        guard !validConfigurations.isEmpty else {
            throw BuildError(message: "No valid data stores could be loaded.")
        }

        let container = try ModelContainer(for: schema, configurations: validConfigurations)
        return (container, excludedPacks)
    }
}


// MARK: - Pack Management
extension SwiftDataPackManager {
    func installPack(from downloadedURL: URL, id: String, title: String, allowsSave: Bool = false) {
         guard downloadedURL.startAccessingSecurityScopedResource() else {
             print("installPack failed: Could not gain security-scoped access to the URL.")
             return
         }
         defer {
             downloadedURL.stopAccessingSecurityScopedResource()
         }

         do {
             let packsDir = try packsDirectory()
             let destMain = packsDir.appendingPathComponent("\(id).store")
             print("Installing pack '\(title)' to: \(destMain.path)")

             if isDirectory(downloadedURL) {
                 let contents = try FileManager.default.contentsOfDirectory(at: downloadedURL, includingPropertiesForKeys: nil)
                 guard let srcMain = contents.first(where: { $0.pathExtension == "store" }) else {
                     throw BuildError(message: "No .store file found in selected folder")
                 }
                 try copySQLiteSet(from: srcMain, to: destMain)
             } else {
                 try copySQLiteSet(from: downloadedURL, to: destMain)
             }

             try validateStore(url: destMain)

             var next = installedPacks.filter { $0.id != id }
             next.append(PackDescriptor(id: id, title: title, fileURL: destMain, allowsSave: allowsSave))
             next.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

             installedPacks = next
             PackStore.save(next)

             reloadContainer()
         } catch {
             print("installPack failed: \(String(describing: error))")
             
             if let packsDir = try? packsDirectory() {
                 let destMain = packsDir.appendingPathComponent("\(id).store")
                 try? FileManager.default.removeItem(at: destMain)
                 try? FileManager.default.removeItem(at: URL(fileURLWithPath: destMain.path + "-wal"))
                 try? FileManager.default.removeItem(at: URL(fileURLWithPath: destMain.path + "-shm"))
             }
         }
     }
    func removePack(id: String, deleteFileFromDisk: Bool = true) async {
        guard let idx = installedPacks.firstIndex(where: { $0.id == id }) else { return }
        let removed = installedPacks.remove(at: idx)
        PackStore.save(installedPacks)
        reloadContainer()
        guard deleteFileFromDisk else { return }
        await deferredDeleteSQLiteStore(at: removed.fileURL)
    }
    
    func containerForPrimaryStore(name: String) -> ModelContainer? {
        guard name == config.mainStoreName else {
            print("containerForPrimaryStore: requested store '\(name)' is not the main store.")
            return nil
        }
        if let cached = primaryStoreContainerCache[name] { return cached }

        let storeURL = primaryStoreURL(for: name)
        let cfg = ModelConfiguration(name,
                                     schema: schema,
                                     url: storeURL,
                                     allowsSave: true)
        do {
            let single = try ModelContainer(for: schema, configurations: [cfg])
            primaryStoreContainerCache[name] = single
            return single
        } catch {
            print("containerForPrimaryStore(\(name)) failed to open \(storeURL.path): \(String(describing: error))")
            return nil
        }
    }

    func containerForPack(id: String, readOnly: Bool = true) -> ModelContainer? {
        if let cached = packContainerCache[id] { return cached }
        guard let pack = installedPacks.first(where: { $0.id == id }) else {
            print("containerForPack: no descriptor for id \(id)")
            return nil
        }

        let cfg = ModelConfiguration(pack.id,
                                     schema: schema,
                                     url: pack.fileURL,
                                     allowsSave: readOnly ? false : pack.allowsSave)
        do {
            let single = try ModelContainer(for: schema, configurations: [cfg])
            packContainerCache[id] = single
            return single
        } catch {
            print("containerForPack(\(id)) failed to open \(pack.fileURL.path): \(String(describing: error))")
            return nil
        }
    }
    
    func invalidateAllCaches() {
        packContainerCache.removeAll()
        primaryStoreContainerCache.removeAll()
    }
}

// MARK: - File Ops / SQLite Set Management
extension SwiftDataPackManager {
    private func primaryStoreURL(for name: String) -> URL {
        Self.primaryStoreURL(for: name, rootURL: rootURL)
    }

    // UPDATED HELPER: Hardcoded to "Packs" for consistency. No longer needs config.
    private func packsDirectory() throws -> URL {
        let dir = rootURL.appendingPathComponent("Packs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func validateStore(url: URL) throws {
        let cfg = ModelConfiguration("validate-\(UUID().uuidString)", schema: schema, url: url, allowsSave: false)
        _ = try ModelContainer(for: schema, configurations: [cfg])
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func copySQLiteSet(from srcMain: URL, to destMain: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destMain.path) { try fm.removeItem(at: destMain) }
        try fm.copyItem(at: srcMain, to: destMain)

        let srcWal = URL(fileURLWithPath: srcMain.path + "-wal")
        let srcShm = URL(fileURLWithPath: srcMain.path + "-shm")
        let destWal = URL(fileURLWithPath: destMain.path + "-wal")
        let destShm = URL(fileURLWithPath: destMain.path + "-shm")

        if fm.fileExists(atPath: srcWal.path) {
            if fm.fileExists(atPath: destWal.path) { try fm.removeItem(at: destWal) }
            try fm.copyItem(at: srcWal, to: destWal)
        }
        if fm.fileExists(atPath: srcShm.path) {
            if fm.fileExists(atPath: destShm.path) { try fm.removeItem(at: destShm) }
            try fm.copyItem(at: srcShm, to: destShm)
        }
    }

    private func deferredDeleteSQLiteStore(at mainURL: URL) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 800_000_000)

        if container.configurations.contains(where: { $0.url == mainURL }) {
            reloadContainer()
            return
        }
        safeRemoveSQLiteSet(at: mainURL)
    }

    private func safeRemoveSQLiteSet(at main: URL) {
        let fm = FileManager.default
        let wal = URL(fileURLWithPath: main.path + "-wal")
        let shm = URL(fileURLWithPath: main.path + "-shm")
        let journal = URL(fileURLWithPath: main.path + "-journal")

        for u in [wal, shm, journal] {
            if fm.fileExists(atPath: u.path) {
                do { try fm.removeItem(at: u) }
                catch { _ = quarantineMoveIfPossible(u) }
            }
        }

        if fm.fileExists(atPath: main.path) {
            do { try fm.removeItem(at: main) }
            catch { _ = quarantineMoveIfPossible(main) }
        }
        cleanupQuarantineSoon()
    }
    
    @discardableResult
    private func quarantineMoveIfPossible(_ url: URL) -> URL? {
        do {
            let q = try quarantineDirectory()
            let dest = q.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            print("quarantineMoveIfPossible failed for \(url.lastPathComponent): \(String(describing: error))")
            return nil
        }
    }

    // UPDATED HELPER: Now nested inside the Packs directory for tidiness.
    private func quarantineDirectory() throws -> URL {
        let packsDir = try packsDirectory()
        let dir = packsDir.appendingPathComponent("PendingDeletion", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanupQuarantineSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let fm = FileManager.default
            if let q = try? quarantineDirectory(),
               let items = try? fm.contentsOfDirectory(at: q, includingPropertiesForKeys: nil) {
                for u in items { try? fm.removeItem(at: u) }
            }
        }
    }

    func cleanupQuarantineOnLaunch() {
        let fm = FileManager.default
        if let q = try? quarantineDirectory(),
           let items = try? fm.contentsOfDirectory(at: q, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
    }
}

// MARK: - Testing & Other Utilities
extension SwiftDataPackManager {
    func addMockPack(title: String, readOnly: Bool = true, seed: (ModelContext) throws -> Void) {
        do {
            // UPDATED: Use Bundle.main.bundleIdentifier directly for consistency.
            guard let bundleID = Bundle.main.bundleIdentifier else {
                throw BuildError(message: "Cannot determine app bundle identifier to generate mock pack ID.")
            }
            let id = "\(bundleID).pack.\(UUID().uuidString)"
            let packsDir = try packsDirectory()
            let dest = packsDir.appendingPathComponent("\(id).store")
            print("Creating mock pack '\(title)' at: \(dest.path)")

            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }

            let seedCfg = ModelConfiguration("seed-\(id)", schema: schema, url: dest, allowsSave: true)
            let temp = try ModelContainer(for: schema, configurations: [seedCfg])
            let ctx = ModelContext(temp)
            
            try seed(ctx)
            try ctx.save()
            try validateStore(url: dest)

            var next = installedPacks
            next.append(PackDescriptor(id: id, title: title, fileURL: dest, allowsSave: !readOnly))
            next.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            installedPacks = next
            PackStore.save(next)

            reloadContainer()
        } catch {
            print("addMockPack failed: \(error)")
        }
    }
    
    func packDirectoryDocument(id: String) throws -> (PackDirectoryDocument, String) {
        guard let pack = installedPacks.first(where: { $0.id == id }) else {
            throw BuildError(message: "No pack with id \(id)")
        }
        let fm = FileManager.default
        let u = pack.fileURL
        var files: [String: Data] = [ "Database.store": try Data(contentsOf: u) ]
        
        let wal = URL(fileURLWithPath: u.path + "-wal")
        let shm = URL(fileURLWithPath: u.path + "-shm")
        if fm.fileExists(atPath: wal.path) { files["Database.store-wal"] = try Data(contentsOf: wal) }
        if fm.fileExists(atPath: shm.path) { files["Database.store-shm"] = try Data(contentsOf: shm) }

        let doc = PackDirectoryDocument(files: files)
        let suggested = pack.title.replacingOccurrences(of: "/", with: "-") + ".pack"
        return (doc, suggested)
    }
}

// MARK: - View Integration
extension SwiftDataPackManager {
    /// Returns the ModelConfiguration for a given container source.
    public func configuration(for source: ContainerSource) -> ModelConfiguration? {
        switch source {
        case .mainStore:
            let storeURL = Self.primaryStoreURL(for: config.mainStoreName, rootURL: rootURL)
            return ModelConfiguration(config.mainStoreName,
                                      schema: schema,
                                      url: storeURL,
                                      allowsSave: true)
            
        case .pack(let id):
            guard let pack = installedPacks.first(where: { $0.id == id }) else {
                print("Configuration request failed: No pack found with ID \(id)")
                return nil
            }
            return ModelConfiguration(pack.id,
                                      schema: schema,
                                      url: pack.fileURL,
                                      allowsSave: pack.allowsSave)
        }
    }
}
