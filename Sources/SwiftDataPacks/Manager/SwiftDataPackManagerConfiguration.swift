import Foundation

public struct SwiftDataPackManagerConfiguration {
    let appName: String
    let appBundleID: String
    let mainStoreName: String
    let packsDirectoryName: String

    public init(appName: String,
                appBundleID: String,
                mainStoreName: String = "Default",
                packsDirectoryName: String = "Packs") {
        self.appName = appName
        self.appBundleID = appBundleID
        self.mainStoreName = mainStoreName
        self.packsDirectoryName = packsDirectoryName
    }
}