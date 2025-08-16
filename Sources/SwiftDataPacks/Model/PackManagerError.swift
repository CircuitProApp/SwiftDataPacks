//
//  PackManagerError.swift
//  SwiftDataPacks
//
//  Created by Giorgi Tchelidze on 8/16/25.
//

import Foundation

/// Defines errors that can be thrown by the SwiftDataPackManager.
public enum PackManagerError: LocalizedError {
    case initializationFailed(reason: String)
    case installationFailed(reason: String)
    case buildError(String)
    case idCollisionDetected

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let reason):
            return "Manager Initialization Failed: \(reason)"
        case .installationFailed(let reason):
            return "Pack Installation Failed: \(reason)"
        case .buildError(let reason):
            return "Build Failed: \(reason)"
        case .idCollisionDetected:
            return "Pack Installation Aborted: One or more items in the pack have the same ID as items in the user's library."
        }
    }
}
