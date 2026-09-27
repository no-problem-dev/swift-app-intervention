import Foundation

/// Where the file-backed stores keep their files. They always add an `AppIntervention/` subdirectory.
///
/// An App Intent that uses `supportedModes` with `.foreground(.dynamic)` runs in the host app's
/// own process, so the App Group is only needed when a widget or another extension reads the
/// data too. Cross-process locations are coordinated with `NSFileCoordinator`; every location
/// is serialized in-process.
public enum FileStoreLocation: Sendable, Hashable {
    /// The shared container of an App Group (always cross-process).
    case appGroup(String)
    /// Any directory. Set `crossProcess` when another process writes the same files.
    case directory(URL, crossProcess: Bool = false)

    /// `<Application Support>/AppIntervention`, single-process.
    public static var applicationSupport: FileStoreLocation {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return .directory(base, crossProcess: false)
    }

    /// The resolved directory, created if needed.
    public func resolve() throws(InterventionError) -> ResolvedFileStoreLocation {
        let base: URL
        let crossProcess: Bool
        switch self {
        case .appGroup(let identifier):
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                throw InterventionError(.appGroupUnavailable, message: "No container for App Group \(identifier). Check the entitlement.")
            }
            base = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            crossProcess = true
        case .directory(let url, let isCrossProcess):
            base = url
            crossProcess = isCrossProcess
        }
        let directory = base.appending(path: "AppIntervention", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw InterventionError(.write, file: directory.lastPathComponent, message: "Could not create directory", underlying: error as NSError)
        }
        return ResolvedFileStoreLocation(directory: directory, crossProcess: crossProcess)
    }
}

/// A resolved ``FileStoreLocation``.
public struct ResolvedFileStoreLocation: Sendable, Hashable {
    public let directory: URL
    public let crossProcess: Bool

    package func file(_ name: String) -> CoordinatedFile {
        CoordinatedFile(url: directory.appending(path: name, directoryHint: .notDirectory), crossProcess: crossProcess)
    }
}
