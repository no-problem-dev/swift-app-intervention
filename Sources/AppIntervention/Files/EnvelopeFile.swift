import Foundation

/// JSON coding for everything on disk: sorted keys, dates as epoch-millisecond integers.
package enum WireCoding {
    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(epochMilliseconds(date))
        }
        return encoder
    }

    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return date(epochMilliseconds: try container.decode(Int64.self))
        }
        return decoder
    }

    package static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    package static func date(epochMilliseconds ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    }
}

/// A JSON file wrapped as `{"formatVersion": N, "payload": …}`.
///
/// - A file with a newer `formatVersion` throws ``InterventionError/Code/unsupportedVersion``
///   and is never rewritten, so an older app build cannot destroy a newer build's data.
/// - An undecodable file is quarantined and treated as absent.
package struct EnvelopeFile<Payload: Codable>: Sendable {
    package let file: CoordinatedFile
    package let formatVersion: Int

    package init(file: CoordinatedFile, formatVersion: Int = 1) {
        self.file = file
        self.formatVersion = formatVersion
    }

    private struct Probe: Decodable { let formatVersion: Int }
    private struct Envelope: Codable {
        let formatVersion: Int
        let payload: Payload
    }

    package func read() throws(InterventionError) -> Payload? {
        try file.withExclusiveAccess { url throws(InterventionError) in try decode(at: url) }
    }

    /// Read-modify-write under exclusive access. Setting the payload to `nil` deletes the file.
    package func modify<T>(_ body: (inout Payload?) -> T) throws(InterventionError) -> T {
        try file.withExclusiveAccess { url throws(InterventionError) in
            var payload = try decode(at: url)
            let result = body(&payload)
            if let payload {
                let data: Data
                do {
                    data = try WireCoding.encoder().encode(Envelope(formatVersion: formatVersion, payload: payload))
                } catch {
                    throw InterventionError(.write, file: file.name, message: "Encoding failed", underlying: error as NSError)
                }
                try file.writeAtomically(data, to: url)
            } else {
                try file.remove(at: url)
            }
            return result
        }
    }

    private func decode(at url: URL) throws(InterventionError) -> Payload? {
        guard let data = try file.readData(at: url) else { return nil }
        let decoder = WireCoding.decoder()
        guard let probe = try? decoder.decode(Probe.self, from: data) else {
            file.quarantine(at: url)
            return nil
        }
        guard probe.formatVersion <= formatVersion else {
            throw InterventionError(
                .unsupportedVersion, file: file.name,
                message: "formatVersion \(probe.formatVersion) is newer than supported \(formatVersion)"
            )
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            file.quarantine(at: url)
            return nil
        }
        return envelope.payload
    }
}
