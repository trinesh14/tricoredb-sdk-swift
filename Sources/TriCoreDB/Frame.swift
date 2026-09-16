import Foundation

/// The wire frame: `version: UInt8 | tag: UInt8 | payloadLength: UInt32 big-endian | payload`.
public enum Frame {

    /// The frame header format this client writes, and the highest it reads.
    public static let version: UInt8 = 1

    /// The fixed header length, in bytes.
    public static let headerSize = 6

    /// The payload ceiling for `REQUEST` and `RESPONSE` frames.
    public static let maxDataPayload = 16 * 1024 * 1024

    /// The payload ceiling for every other frame.
    public static let maxControlPayload = 64 * 1024

    /// A frame tag, as it appears on the wire.
    ///
    /// Note the asymmetry: `HELLO` is answered by `helloOK`, not by `hello`. A client
    /// that waits for the tag it sent waits for ever.
    public enum Tag: UInt8, Sendable, CaseIterable {
        case hello = 0
        case auth = 1
        case request = 2
        case response = 3
        case ping = 4
        case pong = 5
        case error = 6
        case close = 7
        case helloOK = 8
        case authOK = 9
        case bye = 10
        case cancel = 11
        case cancelOK = 12

        /// The largest payload a frame with this tag may carry.
        public var maxPayload: Int {
            switch self {
            case .request, .response: return Frame.maxDataPayload
            default: return Frame.maxControlPayload
            }
        }
    }

    /// The ceiling for a tag byte, whether or not this build knows the tag.
    ///
    /// An unknown tag takes the tighter ceiling deliberately: a tag this build
    /// cannot name is a tag whose payload size it cannot vouch for, and the safe
    /// direction to be wrong in is "too small".
    public static func maxPayload(forTag tag: UInt8) -> Int {
        Tag(rawValue: tag)?.maxPayload ?? maxControlPayload
    }

    /// Encode one frame, refusing a payload above the tag's ceiling.
    public static func encode(tag: Tag, payload: Data) throws -> Data {
        guard payload.count <= tag.maxPayload else {
            throw TriCoreError.protocolViolation(
                "refusing to send a \(payload.count)-byte \(tag) payload; the protocol caps it at \(tag.maxPayload) bytes",
                code: "frame_too_large")
        }
        var out = Data(capacity: headerSize + payload.count)
        out.append(version)
        out.append(tag.rawValue)
        let length = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }

    /// Read a six-byte header, validating it **before** any payload byte is read.
    ///
    /// The declared length is a `UInt32`, so a peer — hostile, broken, or simply on
    /// the wrong port — is six bytes away from asking this client to allocate 4 GiB.
    /// The server refuses such lengths on its side; the client has to refuse them on
    /// its own, because the server is not the only thing a socket can be connected to.
    public static func decodeHeader(_ header: Data) throws -> (tag: UInt8, length: Int) {
        guard header.count == headerSize else {
            throw TriCoreError.protocolViolation("short frame header (\(header.count) bytes)")
        }
        let bytes = [UInt8](header)
        guard bytes[0] <= version else {
            throw TriCoreError.protocolViolation(
                "frame header version \(bytes[0]) is newer than this client can read (max \(version))",
                code: "frame_version")
        }
        let tag = bytes[1]
        let length = Int(bytes[2]) << 24 | Int(bytes[3]) << 16 | Int(bytes[4]) << 8 | Int(bytes[5])
        let limit = maxPayload(forTag: tag)
        guard length <= limit else {
            throw TriCoreError.protocolViolation(
                "a frame with tag \(tag) declares a \(length)-byte payload, above its \(limit)-byte limit",
                code: "frame_too_large")
        }
        return (tag, length)
    }

    /// Decode a payload as JSON, or `nil` when it is empty.
    public static func decodeBody(_ body: Data) throws -> JSONValue? {
        guard !body.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: body)
        } catch {
            throw TriCoreError.protocolViolation("frame payload is not valid JSON: \(error)")
        }
    }

    /// Encode a JSON value as a payload.
    public static func encodeBody(_ value: JSONValue) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw TriCoreError.invalid("cannot encode the request as JSON: \(error)")
        }
    }
}
