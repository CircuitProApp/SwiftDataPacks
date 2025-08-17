# SwiftDataPacks

### A clean separation of user-writable SwiftData and read-only content packs, with ergonomic SwiftUI helpers for setup, filtering, and safe writes.

## Why this exists

Many apps need a single unified view of data while guaranteeing that user edits never mutate bundled or installed content. This package provides three containers (user, packs, main) and the APIs to keep reads simple, writes safe, and pack management robust.

## Requirements

- Swift 5.10+ and SwiftData  
- iOS 17+ or macOS 14+  
- SwiftUI is required for the view modifiers and property wrappers

> [!WARNING]
> SwiftDataPacks uses multiple model containers, but since SwiftData is built on Core Data and doesn’t natively support this pattern, performance may degrade with many packs and unexpected issues can occur. This is a temporary solution for CircuitPro.

## Installation

Add the package URL to your project with Swift Package Manager. Then `import SwiftDataPacks` where needed (automatically imports SwiftData as well).

## Core concepts

The manager builds three `ModelContainers`:  
- `userContainer` (read/write user store)  
- `packsContainer` (read-only packs)  
- `mainContainer` (combined user + packs)  

You read from `mainContainer` by default and write through the provided APIs that enforce user-store-only mutations.

## Quick start

```swift
import SwiftUI
import SwiftDataPacks

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .packContainer(
                    for: [
                        YourModel.self,
                        AnotherModel.self
                    ]
                )
        }
    }
}
```

## Reading from the unified store

```swift
struct ContentView: View {
    @Query(sort: \YourModel.name) var items: [YourModel]

    var body: some View {
        List(items) { item in
            Text(item.name)
        }
    }
}
```

## Safe writes to the user store

```swift
import SwiftDataPacks

struct EditorView: View {
    @UserContext private var user

    var body: some View {
        Button("Add") {
            let item = YourModel(name: "New")
            user.insert(item)
        }

        Button("Rename") {
            user.update(existingItem) { $0.name = "Renamed" }
        }

        Button("Delete") {
            user.delete(existingItem)
        }

        Button("Batch") {
            user.transaction { ctx in
                let a = YourModel(name: "A")
                let b = YourModel(name: "B")
                ctx.insert(a)
                ctx.insert(b)
            }
        }
    }
}
```
> [!INFORMATION]
> Calling CRUD functions on `@UserContext` auto saves if there are real updates, so no need to save it again.

> [!WARNING]
> Don't use `@Environment(\.modelContext)` anymore as this will lead to undefined results (possible write attempt to a pack).

## Transactional write helper for complex edits

```swift
struct BulkOpsView: View {
    @PackManager var manager

    func importMany(_ models: [YourModel]) {
        var write = PackWriteContext(manager: manager)
        for m in models { write.insert(m) }
        try? write.save()
    }
}
```

## Filtering by data source in views

```swift
struct LibraryView: View {
    var body: some View {
        ItemsList()
            .filterContainer(for: .mainStore) // user-only
    }
}

struct PackDetailView: View {
    let packID: UUID
    var body: some View {
        ItemsList()
            .filterContainer(for: .pack(id: packID)) // this pack only
    }
}

struct MixedSourcesView: View {
    let a: UUID, b: UUID
    var body: some View {
        ItemsList()
            .filterContainer(for: .mainStore, .pack(id: a), .pack(id: b))
    }
}
```

## Accessing the manager from SwiftUI

```swift
struct PacksSidebar: View {
    @PackManager var manager

    var body: some View {
        List(manager.installedPacks) { pack in
            Text(pack.metadata.title)
        }
    }
}
```

## Installing and removing packs

```swift
struct InstallButton: View {
    @PackManager var manager

    func install(from folderURL: URL) {
        manager.installPack(from: folderURL)
    }

    func remove(_ packID: UUID) {
        Task { await manager.removePack(id: packID) }
    }
}
```
> [!INFORMATION]
> ℹ️ `installPack(from:)` will check for version diff to ensure no duplicates are installed.

## Exporting packs

```swift
struct ExportPackView: View {
    @PackManager var manager
    @State private var doc: PackDirectoryDocument?
    @State private var name = ""
    @State private var isExporting = false

    let packID: UUID

    var body: some View {
        Button("Export Pack") {
            if let (d, n) = try? manager.packDirectoryDocument(for: packID) {
                doc = d; name = n; isExporting = true
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: doc,
            contentType: .folder,
            defaultFilename: name
        ) { _ in }
    }
}
```

## Mock data for previews and demos

```swift
@PackManager var manager

func installMock() {
    manager.addMockPack(title: "Demo Components") { ctx in
        for i in 1...10 {
            ctx.insert(YourModel(name: "Item \(i)"))
        }
    }
}
```

## Error handling and guardrails

- The manager throws `PackManagerError` on initialization, building containers, and pack operations.  
- Installs perform an ID collision scan between the user store and the incoming pack to prevent duplicated `PersistentIdentifiers`.  
- Writes through `@UserContext` automatically refuse to modify read-only pack objects by re-resolving in the user store.

## Storage layout and lifecycle

- All data lives under Application Support in a root folder derived from your bundle identifier.  
- User data is in a named subdirectory containing the SwiftData store.  
- Packs live in `Packs/<Title>.pack` directories.  
- Deletions fall back to a `PendingDeletion` quarantine when immediate removal fails, and the manager routinely empties quarantine on startup.

## API reference map

- **SwiftDataPackManager**: central coordinator with `userContainer`, `packsContainer`, `mainContainer`, `installedPacks`, and `packsDirectoryURL`.  
- **Property wrappers**: `@PackManager`, `@UserContext`.  
- **View modifiers**: `packContainer(...)`, `filterContainer(for:)`.  
- **Models**: `Pack`, `InstalledPack`, `ContainerSource`, `PackDirectoryDocument`.  
- **Config**: `SwiftDataPackManagerConfiguration`.

## Concurrency and performance notes

- `performWrite` builds a fresh `ModelContext` against the user container, saves only if there are changes, and avoids long-lived shared contexts.  
- Large enumerations use batching to fetch `PersistentIdentifiers` efficiently during collision checks.

## Limitations and gotchas

- Packs must include a `manifest.json` and the SwiftData store files (`.sqlite`, `-wal`, and `-shm` when present).  
- The `PackWriteContext` expects a valid manager.  
- If you hot-swap containers in tight loops, allow the UI a tick to drop old references.
