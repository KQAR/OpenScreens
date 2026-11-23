import CryptoKit
import Security
import XCTest
import RFBProtocol
@testable import RFBTransport

/// The RSA-AES security types: the cipher against published vectors, and the
/// sign-in against a server written here from the same description.
final class RSAAESTests: XCTestCase {

    // MARK: - AES-EAX

    private struct Vector {
        let message, key, nonce, header, sealed: String
    }

    /// From "The EAX Mode of Operation" by Bellare, Rogaway and Wagner.
    private static let vectors = [
        Vector(message: "",
               key: "233952DEE4D5ED5F9B9C6D6FF80FF478",
               nonce: "62EC67F9C3A4A407FCB2A8C49031A8B3",
               header: "6BFB914FD07EAE6B",
               sealed: "E037830E8389F27B025A2D6527E79D01"),
        Vector(message: "F7FB",
               key: "91945D3F4DCBEE0BF45EF52255F095A4",
               nonce: "BECAF043B0A23D843194BA972C66DEBD",
               header: "FA3BFD4806EB53FA",
               sealed: "19DD5C4C9331049D0BDAB0277408F67967E5"),
        Vector(message: "1A47CB4933",
               key: "01F74AD64077F2E704C0F60ADA3DD523",
               nonce: "70C3DB4F0D26368400A10ED05D2BFF5E",
               header: "234A3463C1264AC6",
               sealed: "D851D5BAE03A59F238A23E39199DC9266626C40F80"),
        Vector(message: "481C9E39B1",
               key: "D07CF6CBB7F313BDDE66B727AFD3C5E8",
               nonce: "8408DFFF3C1A2B1292DC199E46B7D617",
               header: "33CCE2EABFF5A79D",
               sealed: "632A9D131AD4C168A4225D8E1FF755939974A7BEDE"),
    ]

    func testEAXMatchesThePublishedVectors() throws {
        for vector in Self.vectors {
            let cipher = try XCTUnwrap(AESEAX(key: hexData(vector.key)))
            let sealed = cipher.seal(
                hexData(vector.message),
                nonce: Array(hexData(vector.nonce)), header: Array(hexData(vector.header)))
            XCTAssertEqual(sealed, hexData(vector.sealed), vector.message)

            let opened = cipher.open(
                hexData(vector.sealed),
                nonce: Array(hexData(vector.nonce)), header: Array(hexData(vector.header)))
            XCTAssertEqual(opened, hexData(vector.message), vector.message)
        }
    }

    func testEAXRefusesAnythingThatWasChanged() throws {
        let cipher = try XCTUnwrap(AESEAX(key: Data(repeating: 7, count: 32)))
        let nonce = [UInt8](repeating: 1, count: 16)
        let header: [UInt8] = [0, 5]
        let sealed = try XCTUnwrap(cipher.seal(Data("hello".utf8), nonce: nonce, header: header))
        XCTAssertEqual(cipher.open(sealed, nonce: nonce, header: header), Data("hello".utf8))

        var changed = sealed
        changed[0] ^= 1
        XCTAssertNil(cipher.open(changed, nonce: nonce, header: header))
        XCTAssertNil(cipher.open(sealed, nonce: nonce, header: [0, 6]))
        XCTAssertNil(cipher.open(sealed, nonce: [UInt8](repeating: 2, count: 16), header: header))
        XCTAssertNil(cipher.open(Data(sealed.dropLast()), nonce: nonce, header: header))
    }

    func testEAXTakesOnlyKeysAESHas() {
        XCTAssertNil(AESEAX(key: Data(count: 15)))
        XCTAssertNil(AESEAX(key: Data(count: 24)))
        XCTAssertNotNil(AESEAX(key: Data(count: 16)))
        XCTAssertNotNil(AESEAX(key: Data(count: 32)))
    }

    // MARK: - Messages

    func testMessagesCarryAStreamInOrderAndInPieces() async throws {
        let (near, far) = PipeEnd.pair()
        let client = try XCTUnwrap(RSAAESConnection(
            base: near, sendKey: Data(repeating: 1, count: 16), receiveKey: Data(repeating: 2, count: 16)))
        let server = try XCTUnwrap(RSAAESConnection(
            base: far, sendKey: Data(repeating: 2, count: 16), receiveKey: Data(repeating: 1, count: 16)))

        // More than one message's worth, to be read back a piece at a time.
        let large = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0) })
        try await client.send(Data("first".utf8))
        try await client.send(large)
        try await client.send(Data("last".utf8))

        let first = try await server.read(exactly: 5)
        XCTAssertEqual(first, Data("first".utf8))
        var received = Data()
        while received.count < large.count {
            received.append(try await server.read(upTo: min(3_000, large.count - received.count)))
        }
        XCTAssertEqual(received, large)
        let last = try await server.read(exactly: 4)
        XCTAssertEqual(last, Data("last".utf8))

        // And the other way, under the other key.
        try await server.send(Data("reply".utf8))
        let reply = try await client.read(exactly: 5)
        XCTAssertEqual(reply, Data("reply".utf8))
    }

    func testAMessageUnderAnotherKeyEndsTheStream() async throws {
        let (near, far) = PipeEnd.pair()
        let client = try XCTUnwrap(RSAAESConnection(
            base: near, sendKey: Data(repeating: 1, count: 16), receiveKey: Data(repeating: 2, count: 16)))
        let stranger = try XCTUnwrap(RSAAESConnection(
            base: far, sendKey: Data(repeating: 9, count: 16), receiveKey: Data(repeating: 1, count: 16)))
        try await stranger.send(Data("hello".utf8))
        do {
            _ = try await client.read(exactly: 5)
            XCTFail("Expected the message to be refused")
        } catch let error as VNCProtocolError {
            guard case .protocolViolation = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Sign-in

    func testSignsInWithAPasswordAndEncryptsTheSession() async throws {
        for type in [SecurityType.ra2, .ra2_256] {
            let outcome = try await signIn(type, username: nil, password: "secret12", server: .init())
            XCTAssertEqual(outcome.server.username, "", "\(type)")
            XCTAssertEqual(outcome.server.password, "secret12", "\(type)")

            // The session goes on inside the same messages, both ways.
            let client = try XCTUnwrap(outcome.client, "\(type)")
            try await outcome.server.secured.send(Data([0, 0, 0, 0]))
            let result = try await client.read(exactly: 4)
            XCTAssertEqual(result, Data([0, 0, 0, 0]))
            try await client.send(Data([1]))
            let clientInit = try await outcome.server.secured.read(exactly: 1)
            XCTAssertEqual(clientInit, Data([1]))
        }
    }

    func testSignsInWithAUserNameWhenTheServerAsksForOne() async throws {
        let outcome = try await signIn(
            .ra2_256, username: "demo", password: "demo-secret",
            server: .init(wantsUsername: true))
        XCTAssertEqual(outcome.server.username, "demo")
        XCTAssertEqual(outcome.server.password, "demo-secret")
    }

    func testTheTypesForSignInOnlyLeaveTheSessionAsItIs() async throws {
        for type in [SecurityType.ra2ne, .ra2ne_256] {
            let outcome = try await signIn(type, username: nil, password: "secret12", server: .init())
            XCTAssertNil(outcome.client, "\(type)")
            XCTAssertEqual(outcome.server.password, "secret12", "\(type)")
        }
    }

    func testAServerThatWantsAUserNameSaysSoWhenThereIsNone() async throws {
        do {
            _ = try await signIn(
                .ra2, username: nil, password: "secret12", server: .init(wantsUsername: true))
            XCTFail("Expected the sign-in to stop")
        } catch let error as VNCProtocolError {
            XCTAssertEqual(error, .authenticationFailed(VNCProtocolError.usernameRequiredReason))
        }
    }

    func testAKeyThatIsNotVouchedForStopsTheSignInBeforeAnythingIsSent() async throws {
        let (near, far) = PipeEnd.pair()
        let server = try TestServer(configuration: .init())
        async let served: Void = { try? await server.sendKey(over: far) }()
        do {
            _ = try await RSAAESAuthenticator(
                securityType: .ra2, host: "pi.example", port: 5900,
                username: nil, password: "secret12",
                keyValidationHandler: { _ in .reject }
            ).authenticate(connection: near)
            XCTFail("Expected the sign-in to stop")
        } catch let error as VNCProtocolError {
            XCTAssertEqual(
                error, .authenticationFailed(VNCProtocolError.serverIdentityRejectedReason))
        }
        await served
        let sent = await far.receivedCount
        XCTAssertEqual(sent, 0, "nothing is sent to a server whose key was turned down")
    }

    func testTheHostIsShownTheKeyTheServerPresented() async throws {
        let seen = Recorded<VNCServerKeyValidationRequest>()
        let outcome = try await signIn(
            .ra2, username: nil, password: "secret12", server: .init(), validation: { request in
                seen.set(request)
                return .acceptAndStore
            })
        let request = try XCTUnwrap(seen.value)
        XCTAssertEqual(request.host, "pi.example")
        XCTAssertEqual(request.port, 5900)
        XCTAssertEqual(request.keyBits, 2048)
        XCTAssertEqual(request.keyData, outcome.server.keyData)
        // Eight bytes of SHA-1 in hexadecimal, as RealVNC and TigerVNC show.
        let expected = Insecure.SHA1.hash(data: outcome.server.keyData).prefix(8)
            .map { String(format: "%02x", $0) }.joined(separator: "-")
        XCTAssertEqual(request.signature, expected)
        XCTAssertEqual(request.signature.count, 23)
    }

    func testAServerThatDoesNotHoldTheKeyItPresentedIsRefused() async throws {
        do {
            _ = try await signIn(
                .ra2, username: nil, password: "secret12", server: .init(provesKey: false))
            XCTFail("Expected the sign-in to stop")
        } catch let error as VNCProtocolError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testPublicKeysSurviveTheirEncoding() throws {
        let modulus = Data([0x80, 0x01, 0x02]) + Data(repeating: 0xab, count: 253)
        let exponent = Data([0x01, 0x00, 0x01])
        let der = RSAAESAuthenticator.derSequence(
            RSAAESAuthenticator.derInteger(modulus) + RSAAESAuthenticator.derInteger(Data(count: 5) + exponent))
        let parsed = try XCTUnwrap(RSAAESAuthenticator.parsePublicKey(der))
        XCTAssertEqual(parsed.modulus, modulus)
        XCTAssertEqual(parsed.exponent, exponent)
        XCTAssertNil(RSAAESAuthenticator.parsePublicKey(Data(der.dropLast())))
    }

    // MARK: - Support

    private struct Outcome {
        let client: RSAAESConnection?
        let server: TestServer.Session
    }

    private func signIn(
        _ type: SecurityType,
        username: String?,
        password: String,
        server configuration: TestServer.Configuration,
        validation: @escaping VNCServerKeyValidationHandler = { _ in .acceptAndStore }
    ) async throws -> Outcome {
        let (near, far) = PipeEnd.pair()
        let server = try TestServer(configuration: configuration)
        async let served = server.serve(type, over: far)
        do {
            let client = try await RSAAESAuthenticator(
                securityType: type, host: "pi.example", port: 5900,
                username: username, password: password,
                keyValidationHandler: validation
            ).authenticate(connection: near)
            return Outcome(client: client, server: try await served)
        } catch {
            // The server is left waiting for a client that has gone.
            await far.close()
            _ = try? await served
            throw error
        }
    }
}

/// One end of a byte stream held in memory.
private actor PipeEnd: RFBConnection {
    private var buffer = Data()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var peer: PipeEnd?
    private var isClosed = false
    private(set) var receivedCount = 0

    static func pair() -> (PipeEnd, PipeEnd) {
        let near = PipeEnd(), far = PipeEnd()
        Task { await near.attach(far) }
        Task { await far.attach(near) }
        return (near, far)
    }

    private func attach(_ peer: PipeEnd) {
        self.peer = peer
        wake()
    }

    private func wake() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    private func deliver(_ data: Data) {
        buffer.append(data)
        receivedCount += data.count
        wake()
    }

    private func peerClosed() {
        isClosed = true
        wake()
    }

    func connect() async throws {}

    func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            if isClosed { throw VNCProtocolError.connectionClosed }
            await withCheckedContinuation { waiters.append($0) }
        }
        let bytes = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return bytes
    }

    func read(upTo maxCount: Int) async throws -> Data {
        while buffer.isEmpty {
            if isClosed { throw VNCProtocolError.connectionClosed }
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await read(exactly: min(maxCount, buffer.count))
    }

    func send(_ data: Data) async throws {
        while peer == nil {
            await withCheckedContinuation { waiters.append($0) }
        }
        await peer?.deliver(data)
    }

    func close() async {
        isClosed = true
        wake()
        await peer?.peerClosed()
    }

    func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {}
}

/// The server's half of the sign-in, written from the description of the
/// security types and not from the client.
private struct TestServer: @unchecked Sendable {
    struct Configuration {
        var wantsUsername = false
        /// Whether the server answers with the hash that shows it saw both
        /// keys.
        var provesKey = true
    }

    struct Session {
        let username: String
        let password: String
        let keyData: Data
        let secured: RSAAESConnection
    }

    let configuration: Configuration
    private let privateKey: SecKey
    private let modulus: Data
    private let exponent: Data

    init(configuration: Configuration) throws {
        self.configuration = configuration
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let exported = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(try XCTUnwrap(SecKeyCopyPublicKey(key)), &error) as Data?)
        let parts = try XCTUnwrap(RSAAESAuthenticator.parsePublicKey(exported))
        privateKey = key
        modulus = parts.modulus
        exponent = parts.exponent
    }

    var keyData: Data {
        Self.uint32(2048) + Self.padded(modulus, to: 256) + Self.padded(exponent, to: 256)
    }

    func sendKey(over connection: PipeEnd) async throws {
        try await connection.send(keyData)
    }

    func serve(_ type: SecurityType, over connection: PipeEnd) async throws -> Session {
        let usesSHA256 = type == .ra2_256 || type == .ra2ne_256
        let randomSize = usesSHA256 ? 32 : 16
        func digest(_ data: Data) -> Data {
            usesSHA256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
        }

        try await sendKey(over: connection)

        let clientBits = Int(Self.value(try await connection.read(exactly: 4)))
        let clientSize = (clientBits + 7) / 8
        let clientModulus = try await connection.read(exactly: clientSize)
        let clientExponent = try await connection.read(exactly: clientSize)
        let clientKeyData = Self.uint32(UInt32(clientBits)) + clientModulus + clientExponent
        let clientKey = try RSAPublicKey(derData: RSAAESAuthenticator.derSequence(
            RSAAESAuthenticator.derInteger(clientModulus)
                + RSAAESAuthenticator.derInteger(clientExponent))).secKey

        var error: Unmanaged<CFError>?
        let encryptedSize = Int(Self.value(try await connection.read(exactly: 2)))
        let encryptedRandom = try await connection.read(exactly: encryptedSize)
        let clientRandom = try XCTUnwrap(SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionPKCS1, encryptedRandom as CFData, &error) as Data?)
        XCTAssertEqual(clientRandom.count, randomSize)

        let serverRandom = Data((0..<randomSize).map { _ in UInt8.random(in: 0...255) })
        let encrypted = try XCTUnwrap(SecKeyCreateEncryptedData(
            clientKey, .rsaEncryptionPKCS1, serverRandom as CFData, &error) as Data?)
        // Without its leading zeros, as a number is written when nobody
        // pads it: a client has to take it either way.
        let written = Data(encrypted.drop(while: { $0 == 0 }))
        try await connection.send(Self.uint16(UInt16(written.count)) + written)

        // The server's keys are the client's, the other way round.
        let secured = try XCTUnwrap(RSAAESConnection(
            base: connection,
            sendKey: Data(digest(clientRandom + serverRandom).prefix(randomSize)),
            receiveKey: Data(digest(serverRandom + clientRandom).prefix(randomSize))))

        let clientHash = try await secured.read(exactly: usesSHA256 ? 32 : 20)
        XCTAssertEqual(clientHash, digest(clientKeyData + keyData))
        let proof = digest(keyData + clientKeyData)
        try await secured.send(configuration.provesKey ? proof : Data(proof.reversed()))

        try await secured.send(Data([configuration.wantsUsername ? 1 : 2]))
        let nameLength = Int(try await secured.read(exactly: 1)[0])
        let name = try await secured.read(exactly: nameLength)
        let passwordLength = Int(try await secured.read(exactly: 1)[0])
        let password = try await secured.read(exactly: passwordLength)
        return Session(
            username: String(decoding: name, as: UTF8.self),
            password: String(decoding: password, as: UTF8.self),
            keyData: keyData,
            secured: secured)
    }

    private static func padded(_ value: Data, to size: Int) -> Data {
        Data(count: size - value.count) + value
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private static func value(_ data: Data) -> UInt32 {
        data.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

private final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
