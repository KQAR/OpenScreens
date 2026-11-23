import Foundation
import RFBProtocol

/// A byte stream carried in the encrypted messages of the RSA-AES security
/// types.
///
/// Each message is two bytes of length, as many bytes of AES-EAX ciphertext
/// and a 16-byte tag. The length is authenticated but not encrypted, and the
/// nonce is a count of the messages sent in that direction, so a message
/// that is changed, dropped or put out of order stops the session.
///
/// It wraps whatever connection the session was dialled over, an SSH tunnel
/// included, and takes its place once the keys are agreed.
public actor RSAAESConnection: RFBConnection {
    /// The most plaintext one message carries. Every implementation sends
    /// messages this size and none is known to refuse them.
    static let largestMessage = 8192

    private let base: any RFBConnection
    private let sending: AESEAX
    private let receiving: AESEAX
    private var sendCounter = [UInt8](repeating: 0, count: 16)
    private var receiveCounter = [UInt8](repeating: 0, count: 16)

    /// Decrypted bytes not yet read, from `cursor` on.
    private var buffer = Data()
    private var cursor = 0

    private var isSending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReading = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - sendKey: The key for what this end sends.
    ///   - receiveKey: The key for what the other end sends.
    init?(base: any RFBConnection, sendKey: Data, receiveKey: Data) {
        guard let sending = AESEAX(key: sendKey),
              let receiving = AESEAX(key: receiveKey) else { return nil }
        self.base = base
        self.sending = sending
        self.receiving = receiving
    }

    // MARK: - RFBConnection

    /// The connection underneath was dialled before the keys were agreed.
    public func connect() async throws {}

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        await beginReading()
        defer { endReading() }
        while available < count {
            try await readMessage()
        }
        return take(count)
    }

    public func read(upTo maxCount: Int) async throws -> Data {
        guard maxCount > 0 else { return Data() }
        await beginReading()
        defer { endReading() }
        while available == 0 {
            try await readMessage()
        }
        return take(min(maxCount, available))
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        // Messages have to reach the wire in the order they were sealed in:
        // each carries its place in the count. One send is sealed and
        // handed over whole before the next begins.
        await beginSending()
        defer { endSending() }
        var sealed = Data(capacity: data.count + (data.count / Self.largestMessage + 1) * 18)
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + Self.largestMessage, data.endIndex)
            let length = end - offset
            let header = [UInt8(length >> 8), UInt8(length & 0xff)]
            guard let message = sending.seal(data[offset..<end], nonce: sendCounter, header: header) else {
                throw VNCProtocolError.ioError("A message could not be encrypted")
            }
            Self.increment(&sendCounter)
            sealed.append(contentsOf: header)
            sealed.append(message)
            offset = end
        }
        // What is sealed is sent even if whoever asked has stopped waiting:
        // a message counted and not sent would put every later one out of
        // step.
        let base = base
        let outcome = sealed
        try await Task { try await base.send(outcome) }.value
    }

    public func close() async {
        await base.close()
    }

    public func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {
        await base.setDisconnectHandler(handler)
    }

    public func pathCharacteristics() async -> NetworkPathCharacteristics? {
        await base.pathCharacteristics()
    }

    public func remoteEndpointHost() async -> String? {
        await base.remoteEndpointHost()
    }

    // MARK: - Messages

    private var available: Int { buffer.count - cursor }

    private func take(_ count: Int) -> Data {
        let start = buffer.startIndex + cursor
        let bytes = buffer.subdata(in: start..<(start + count))
        cursor += count
        if cursor == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor >= 1 << 20 {
            // A reader that never quite catches up must not make the
            // buffer grow for as long as the session lasts.
            buffer = buffer.subdata(in: (buffer.startIndex + cursor)..<buffer.endIndex)
            cursor = 0
        }
        return bytes
    }

    private func readMessage() async throws {
        let header = try await base.read(exactly: 2)
        let bytes = Array(header)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        let sealed = try await base.read(exactly: length + AESEAX.tagSize)
        guard let plaintext = receiving.open(sealed, nonce: receiveCounter, header: bytes) else {
            throw VNCProtocolError.protocolViolation(
                "An encrypted message from the server was not what the server sent")
        }
        Self.increment(&receiveCounter)
        buffer.append(plaintext)
    }

    /// The count of messages, as the 128-bit little-endian number the nonce is.
    private static func increment(_ counter: inout [UInt8]) {
        for index in counter.indices {
            counter[index] &+= 1
            if counter[index] != 0 { break }
        }
    }

    // MARK: - One at a time

    private func beginReading() async {
        while isReading {
            await withCheckedContinuation { readWaiters.append($0) }
        }
        isReading = true
    }

    private func endReading() {
        isReading = false
        if !readWaiters.isEmpty {
            readWaiters.removeFirst().resume()
        }
    }

    private func beginSending() async {
        while isSending {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        isSending = true
    }

    private func endSending() {
        isSending = false
        if !sendWaiters.isEmpty {
            sendWaiters.removeFirst().resume()
        }
    }
}
