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

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let reason):
            return "Manager Initialization Failed: \(reason)"
        case .installationFailed(let reason):
            return "Pack Installation Failed: \(reason)"
        case .buildError(let reason):
            return "Build Failed: \(reason)"
        }
    }
}
