import Foundation
import Synchronization

/// Process-wide state for one file path, shared by every store instance that opens it.
///
/// Two store instances on the same directory must not race: they share this lock (and the
/// handoff's change stream) because the registry is keyed by the standardized path.
package final class SharedFileState: @unchecked Sendable {
    /// Serializes access to the file within this process.
    package let lock = NSLock()
    /// Cached line count of a JSONL file. Read and written only while holding ``lock``.
    package var lineCount: Int?
    /// Changes of a handoff file, shared by every handoff instance on the same path.
    package let handoffChanges = Broadcaster<HandoffChange>()

    private static let registry = Mutex<[String: SharedFileState]>([:])

    package static func state(for url: URL) -> SharedFileState {
        let key = url.standardizedFileURL.path(percentEncoded: false)
        return registry.withLock { states in
            if let existing = states[key] { return existing }
            let created = SharedFileState()
            states[key] = created
            return created
        }
    }
}

/// One file with serialized access: a per-path lock shared across instances in this process,
/// plus `NSFileCoordinator` when other processes may write it too.
package final class CoordinatedFile: Sendable {
    package let url: URL
    package let crossProcess: Bool
    package let shared: SharedFileState

    package init(url: URL, crossProcess: Bool) {
        self.url = url
        self.crossProcess = crossProcess
        self.shared = SharedFileState.state(for: url)
    }

    package var name: String { url.lastPathComponent }

    /// Runs `body` with exclusive access to the file for a read-modify-write.
    package func withExclusiveAccess<T>(_ body: (URL) throws(InterventionError) -> T) throws(InterventionError) -> T {
        shared.lock.lock()
        defer { shared.lock.unlock() }

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

    /// Appends with `O_APPEND`. When the file does not end with a newline (a torn write),
    /// a newline is written first so the new line is not glued to the broken one.
    package func appendLine(_ line: Data, to url: URL) throws(InterventionError) {
        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            var attributes: [FileAttributeKey: Any] = [:]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            guard FileManager.default.createFile(atPath: path, contents: Data(), attributes: attributes) else {
                throw InterventionError(.write, file: name, message: "Could not create file")
            }
        }
        let fd = open(path, O_RDWR | O_APPEND)
        guard fd >= 0 else { throw InterventionError(.write, file: name, message: "open failed: errno \(errno)") }
        defer { close(fd) }

        var payload = line
        let size = lseek(fd, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, size - 1) == 1, last != 0x0A {
                payload.insert(0x0A, at: 0)
            }
        }
        let written = payload.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let result = write(fd, base + offset, buffer.count - offset)
                if result <= 0 { return -1 }
                offset += result
            }
            return offset
        }
        guard written == payload.count else { throw InterventionError(.write, file: name, message: "write failed: errno \(errno)") }
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

/// A file resolved lazily from a ``FileStoreLocation``, so building a store never throws:
/// a missing App Group or directory surfaces as an error on first use, where the automation
/// path fails open.
package final class FileRef: Sendable {
    private let location: FileStoreLocation?
    private let name: String
    private let cached: Mutex<CoordinatedFile?>

    package init(location: FileStoreLocation, name: String) {
        self.location = location
        self.name = name
        self.cached = Mutex(nil)
    }

    package init(resolved: ResolvedFileStoreLocation, name: String) {
        self.location = nil
        self.name = name
        self.cached = Mutex(resolved.file(name))
    }

    package func get() throws(InterventionError) -> CoordinatedFile {
        if let file = cached.withLock({ $0 }) { return file }
        guard let location else { throw InterventionError(.read, file: name, message: "No location") }
        let file = try location.resolve().file(name)
        cached.withLock { $0 = file }
        return file
    }
}
