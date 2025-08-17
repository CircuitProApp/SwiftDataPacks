# SwiftDataPacks

### A clean separation of user-writable SwiftData and read-only content packs, with ergonomic SwiftUI helpers for setup, filtering, and safe writes.

## Why this exists

Many apps need to present a single, unified view of data while guaranteeing that user edits can never mutate bundled or installed content. This package provides a single, composite `ModelContainer` built from the user's private, writable data store and any number of read-only "pack" stores. It includes the APIs to keep reads simple, writes safe, and pack management robust.

## Requirements

- Swift 5.10+ and SwiftData
- iOS 17+ or macOS 14+
- SwiftUI is required for the view modifiers and property wrappers

> [!WARNING]
> SwiftDataPacks uses a single ModelContainer composed of multiple underlying stores. Since SwiftData is built on Core Data and doesn’t natively advertise this pattern, performance may degrade with many packs and unexpected issues can occur. This is a temporary solution for CircuitPro.

## Installation

Add the package URL to your project with Swift Package Manager. Then `import SwiftDataPacks` where needed (this automatically imports SwiftData as well).

## Core Concepts

The manager builds a **single, composite `ModelContainer`** that merges two types of data sources:
- **The User Store**: A private, read-write database located in the app's Application Support directory.
- **Content Packs**: Any number of read-only databases that can be installed or updated at runtime.

You read from this unified `mainContainer` by default and write exclusively to the user store through provided APIs that enforce this separation.

## Quick Start

```swift
import SwiftUI
import SwiftDataPacks

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The container is configured with just your model types.
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

> [!WARNING]
> Do not use the default `.modelContainer()` in conjunction with `.packContainer()`, it will lead to unexpected results.

## Reading from the Unified Store

Standard `@Query` works out of the box and will fetch data from both the user's store and all installed packs.

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

## Safe Writes to the User Store

The `@UserContext` property wrapper is the **only** supported way to write data. It provides a safe API that guarantees all mutations only affect the user's private database.

```swift
import SwiftDataPacks

struct EditorView: View {
    @UserContext private var user

    var body: some View {
        Button("Add New Item") {
            let item = YourModel(name: "New")
            user.insert(item)
        }

        Button("Rename Item") {
            // 'existingItem' could be from a pack or the user's store.
            // This update will only apply if it's a user-owned item.
            user.update(existingItem) { $0.name = "Renamed" }
        }

        Button("Delete Item") {
            user.delete(existingItem)
        }

        Button("Batch Operation") {
            user.transaction { context in
                let a = YourModel(name: "Item A")
                let b = YourModel(name: "Item B")
                context.insert(a)
                context.insert(b)
            }
        }
    }
}
```

> [!IMPORTANT]
> Calling the `insert`, `update`, or `delete` methods on `@UserContext` automatically saves changes in a safe, isolated transaction. You do not need to call save.

> [!WARNING]
> Do not use `@Environment(\.modelContext)` to perform writes. This will lead to undefined behavior, including potential attempts to write to a read-only pack, which will cause a crash.

## Filtering by Data Source in Views

Use the `.filterContainer` modifier to scope any view and its children to specific data sources.

```swift
struct LibraryView: View {
    var body: some View {
        // This list will only show items from the user's private store.
        ItemsList()
            .filterContainer(for: .mainStore)
    }
}

struct PackDetailView: View {
    let packID: UUID
    var body: some View {
        // This list will only show items from one specific pack.
        ItemsList()
            .filterContainer(for: .pack(id: packID))
    }
}

struct MixedSourcesView: View {
    let packA: UUID, packB: UUID
    var body: some View {
        // This list shows items from the user store and two specific packs.
        ItemsList()
            .filterContainer(for: .mainStore, .pack(id: packA), .pack(id: packB))
    }
}
```

## Accessing the Manager from SwiftUI

Use the `@PackManager` property wrapper to get access to the manager for listing packs or performing other operations.

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

## Installing and Removing Packs

The pack management functions now `throw` errors, allowing you to catch failures and present alerts to the user.

```swift
struct InstallButton: View {
    @PackManager var manager
    @State private var error: Error?

    func install(from folderURL: URL) {
        do {
            try manager.installPack(from: folderURL)
        } catch {
            self.error = error // Trigger a .alert modifier
        }
    }

    func remove(_ packID: UUID) {
        manager.removePack(id: packID)
    }
}```

> [!IMPORTANT]
> `installPack(from:)` will automatically check the pack's version. If a pack with the same ID is already installed, it will perform an update instead of installing a duplicate.

## Exporting Packs

```swift
struct ExportPackView: View {
    @PackManager var manager
    @State private var document: PackDirectoryDocument?
    @State private var filename = ""
    @State private var isExporting = false

    let packID: UUID

    var body: some View {
        Button("Export Pack") {
            if let (doc, name) = try? manager.packDirectoryDocument(for: packID) {
                document = doc
                filename = name
                isExporting = true
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .folder,
            defaultFilename: filename
        ) { _ in }
    }
}
```

## Mock Data for Previews and Demos

Quickly create and install a pack for testing or SwiftUI Previews.

```swift
struct MyView_Previews: PreviewProvider {
    static var previews: some View {
        MyView()
            .onAppear {
                // Using a temporary manager for the preview
                if let manager = try? SwiftDataPackManager(for: [YourModel.self]) {
                    do {
                        try manager.addMockPack(title: "Demo Components") { ctx in
                            for i in 1...10 {
                                ctx.insert(YourModel(name: "Item \(i)"))
                            }
                        }
                    } catch {
                        print("Failed to add mock pack: \(error)")
                    }
                }
            }
    }
}
```

## Error Handling and Guardrails

- The manager throws `PackManagerError` on initialization and pack operations like `installPack`.
- Installs perform an ID collision scan between the user store and the incoming pack to prevent duplicated `PersistentIdentifiers`.
- Writes through `@UserContext` automatically refuse to modify read-only pack objects by safely re-fetching the object in the user-only write context.

## Storage Layout and Lifecycle

- All data lives under Application Support in a `SwiftDataPacks` folder.
- User data is in the `Main` subdirectory, containing the `database.store`.
- Packs live in `Packs/<Title>.pack` directories.
- Deletions fall back to a "pending deletion" list when immediate removal fails, and the manager cleans up these files on the next app launch.

## API Reference Map

- **SwiftDataPackManager**: The central coordinator with `mainContainer`, `installedPacks`, and `packsDirectoryURL`.
- **Property Wrappers**: `@PackManager`, `@UserContext`.
- **View Modifiers**: `packContainer(for:)`, `filterContainer(for:)`.
- **Models**: `Pack`, `InstalledPack`, `ContainerSource`, `PackDirectoryDocument`.

## Concurrency and Performance Notes

- The manager creates a fresh, temporary `ModelContext` for every write transaction to ensure isolation and prevent concurrency issues.
- Large enumerations use batching to fetch `PersistentIdentifiers` efficiently during collision checks.

## Limitations and Gotchas

- Packs must include a `manifest.json` and the SwiftData store files (`.store`, `-wal`, and `-shm` when present).
- If you hot-swap containers by installing/removing packs in tight loops, allow the UI a cycle to update its references.
