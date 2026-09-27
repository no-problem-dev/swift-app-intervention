import Foundation

/// One file with serialized access: an in-process lock always, plus `NSFileCoordinator` when
/// other processes may write it too.
package final class CoordinatedFile: Sendable {
    package let url: URL
    package let crossProcess: Bool
    private let lock = NSLock()

    package init(url: URL, crossProcess: Bool) {
        self.url = url
        self.crossProcess = crossProcess
    }

    package var name: String { url.lastPathComponent }

    /// Runs `body` with exclusive access to the file for a read-modify-write.
    package func withExclusiveAccess<T>(_ body: (URL) throws(InterventionError) -> T) throws(InterventionError) -> T {
        lock.lock()
        defer { lock.unlock() }

        guard crossProcess else { return try body(url) }

        var outcome: Result<T, InterventionError>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            do throws(InterventionError) {
                outcome = .success(try body(coordinatedURL))
            } catch {
                outcome = .failure(error)
            }
        }
        if let outcome { return try outcome.get() }
        throw InterventionError(.read, file: name, message: "File coordination failed", underlying: coordinationError)
    }

    // MARK: - Primitives (call inside withExclusiveAccess)

    /// `nil` when the file does not exist.
    package func readData(at url: URL) throws(InterventionError) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw InterventionError(.read, file: name, underlying: error as NSError)
        }
    }

    package func writeAtomically(_ data: Data, to url: URL) throws(InterventionError) {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Readable by an intent that runs while the device is locked, after the first unlock.
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        do {
            try data.write(to: url, options: options)
        } catch {
            throw InterventionError(.write, file: name, underlying: error as NSError)
        }
    }

    package func append(_ data: Data, to url: URL) throws(InterventionError) {
        let path = url.path(percentEncoded: false)
        do {
            if !FileManager.default.fileExists(atPath: path) {
                var attributes: [FileAttributeKey: Any] = [:]
                #if os(iOS)
                attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
                #endif
                guard FileManager.default.createFile(atPath: path, contents: data, attributes: attributes) else {
                    throw InterventionError(.write, file: name, message: "Could not create file")
                }
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch let error as InterventionError {
            throw error
        } catch {
            throw InterventionError(.write, file: name, underlying: error as NSError)
        }
    }

    package func remove(at url: URL) throws(InterventionError) {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw InterventionError(.write, file: name, underlying: error as NSError)
        }
    }

    /// Moves an undecodable file aside (`<name>.corrupt-<epochms>`), keeping it as evidence.
    package func quarantine(at url: URL, now: Date = Date()) {
        let stamp = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
