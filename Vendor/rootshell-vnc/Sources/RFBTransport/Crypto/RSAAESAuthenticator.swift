import CryptoKit
import Foundation
import RFBProtocol
import Security

/// The key an RSA-AES server proves it is the same server with.
///
/// Nothing vouches for the key but the person connecting: the host is asked,
/// and is expected to remember the answer.
public struct VNCServerKeyValidationRequest: Sendable {
    public let host: String
    public let port: UInt16
    public let keyBits: Int
    /// The key as the server sent it: its length in bits, its modulus and
    /// its exponent.
    public let keyData: Data

    public init(host: String, port: UInt16, keyBits: Int, keyData: Data) {
        self.host = host
        self.port = port
        self.keyBits = keyBits
        self.keyData = keyData
    }

    /// What RealVNC Server shows as its signature and TigerVNC as a
    /// fingerprint: the first eight bytes of the key's SHA-1, in hexadecimal.
    public var signature: String {
        Insecure.SHA1.hash(data: keyData).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined(separator: "-")
    }

    /// The whole of the key's SHA-256, for telling one key from another.
    public var sha256: Data {
        Data(SHA256.hash(data: keyData))
    }
}

public typealias VNCServerKeyValidationHandler = @Sendable (
    VNCServerKeyValidationRequest
) async -> VNCCertificateValidationResult

/// The RSA-AES security types: RA2 and RA2ne, and their 256-bit forms.
///
/// The two ends exchange RSA public keys and a random number each, encrypted
/// to the other's key, and make an AES key for each direction from the pair.
/// The user name and password then travel encrypted. With RA2 so does the
/// whole session after them; with RA2ne ("no encryption") only the sign-in
/// was protected.
///
/// This is what a RealVNC server speaks by default, and what wayvnc offers
/// beside TLS.
public struct RSAAESAuthenticator: Sendable {
    /// Sub-types the server chooses between after the keys are agreed.
    private enum Credentials: UInt8 {
        case usernameAndPassword = 1
        case password = 2
    }

    private static let clientKeyBits = 2048
    private static let serverKeyBits = 1024...8192

    private let securityType: SecurityType
    private let host: String
    private let port: UInt16
    private let username: String?
    private let password: String
    private let keyValidationHandler: VNCServerKeyValidationHandler?
    private let log = VNCLogger(category: "RSA-AES")

    public init(
        securityType: SecurityType,
        host: String,
        port: UInt16,
        username: String?,
        password: String,
        keyValidationHandler: VNCServerKeyValidationHandler?
    ) {
        self.securityType = securityType
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.keyValidationHandler = keyValidationHandler
    }

    /// Signs in.
    ///
    /// - Returns: The connection the rest of the session has to use, when
    ///   the security type encrypts all of it; `nil` when what follows is
    ///   sent as it is.
    public func authenticate(connection: any RFBConnection) async throws -> RSAAESConnection? {
        let usesSHA256 = securityType == .ra2_256 || securityType == .ra2ne_256
        let randomSize = usesSHA256 ? 32 : 16

        // The server's key.
        let serverBits = Int(Self.uint32(try await connection.read(exactly: 4)))
        guard Self.serverKeyBits.contains(serverBits) else {
            throw VNCProtocolError.authenticationFailed(
                "The server's key is \(serverBits) bits long, which is not a size that can be used")
        }
        let serverSize = (serverBits + 7) / 8
        let serverModulus = try await connection.read(exactly: serverSize)
        let serverExponent = try await connection.read(exactly: serverSize)
        let serverKeyData = Self.bigEndian(UInt32(serverBits)) + serverModulus + serverExponent

        guard let keyValidationHandler else {
            throw VNCProtocolError.authenticationFailed(
                "The server's key could not be checked")
        }
        let verdict = await keyValidationHandler(VNCServerKeyValidationRequest(
            host: host, port: port, keyBits: serverBits, keyData: serverKeyData))
        guard verdict != .reject else {
            throw VNCProtocolError.authenticationFailed(VNCProtocolError.serverIdentityRejectedReason)
        }
        let serverKey = try Self.publicKey(modulus: serverModulus, exponent: serverExponent)

        // This end's key, made for this connection and gone with it.
        let clientKey = try Self.makeKey()
        let clientSize = Self.clientKeyBits / 8
        let clientKeyData = Self.bigEndian(UInt32(Self.clientKeyBits))
            + Self.padded(clientKey.modulus, to: clientSize)
            + Self.padded(clientKey.exponent, to: clientSize)
        try await connection.send(clientKeyData)

        // A random number each way, readable only by the key it is sent to.
        var clientRandom = Data(count: randomSize)
        let filled = clientRandom.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, randomSize, $0.baseAddress!)
        }
        guard filled == errSecSuccess else {
            throw VNCProtocolError.ioError("No random numbers could be had")
        }
        let encryptedRandom = try Self.encrypt(clientRandom, to: serverKey)
        try await connection.send(Self.bigEndian(UInt16(encryptedRandom.count)) + encryptedRandom)

        // As long as this end's key, as a rule. A server that writes the
        // number without its leading zeros sends fewer bytes once in a few
        // hundred connections, and they go back on before it is decrypted.
        let serverRandomSize = Int(Self.uint16(try await connection.read(exactly: 2)))
        guard (1...clientSize).contains(serverRandomSize) else {
            throw VNCProtocolError.protocolViolation(
                "The server encrypted its random number to a key of another size")
        }
        let serverRandom = try Self.decrypt(
            Self.padded(try await connection.read(exactly: serverRandomSize), to: clientSize),
            with: clientKey.privateKey)
        guard serverRandom.count == randomSize else {
            throw VNCProtocolError.protocolViolation(
                "The server's random number is not the size this security type uses")
        }

        // A key for each direction, from both numbers.
        func digest(_ data: Data) -> Data {
            usesSHA256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
        }
        let sendKey = digest(serverRandom + clientRandom).prefix(randomSize)
        let receiveKey = digest(clientRandom + serverRandom).prefix(randomSize)
        guard let secured = RSAAESConnection(
            base: connection, sendKey: Data(sendKey), receiveKey: Data(receiveKey)) else {
            throw VNCProtocolError.ioError("The session keys could not be set up")
        }

        // Each end shows the other it saw the same two keys, which is what
        // ties the encrypted session to the key the user was asked about.
        try await secured.send(digest(clientKeyData + serverKeyData))
        let expected = digest(serverKeyData + clientKeyData)
        let serverHash = try await secured.read(exactly: expected.count)
        guard serverHash == expected else {
            throw VNCProtocolError.authenticationFailed(
                "The server did not prove it holds the key it presented")
        }

        let subtype = try await secured.read(exactly: 1)
        guard let wanted = subtype.first.flatMap(Credentials.init(rawValue:)) else {
            throw VNCProtocolError.authenticationFailed(
                "The server asked for a kind of sign-in that is not known")
        }
        let name: Data
        switch wanted {
        case .usernameAndPassword:
            guard let username, !username.isEmpty else {
                throw VNCProtocolError.authenticationFailed(VNCProtocolError.usernameRequiredReason)
            }
            name = Data(username.utf8)
        case .password:
            name = Data()
        }
        let secret = Data(password.utf8)
        guard name.count <= 255, secret.count <= 255 else {
            throw VNCProtocolError.authenticationFailed(
                "The user name or password is too long for this server")
        }
        try await secured.send(
            Data([UInt8(name.count)]) + name + Data([UInt8(secret.count)]) + secret)
        log.info("Signed in with \(securityType), \(wanted)")

        let encryptsSession = securityType == .ra2 || securityType == .ra2_256
        return encryptsSession ? secured : nil
    }

    // MARK: - RSA

    private struct ClientKey: @unchecked Sendable {
        let privateKey: SecKey
        let modulus: Data
        let exponent: Data
    }

    private static func makeKey() throws -> ClientKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: clientKeyBits,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let exported = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let parts = parsePublicKey(exported) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw VNCProtocolError.ioError("A key for this connection could not be made: \(reason)")
        }
        return ClientKey(privateKey: privateKey, modulus: parts.modulus, exponent: parts.exponent)
    }

    private static func publicKey(modulus: Data, exponent: Data) throws -> SecKey {
        let der = derSequence(derInteger(modulus) + derInteger(exponent))
        return try RSAPublicKey(derData: der).secKey
    }

    private static func encrypt(_ plaintext: Data, to key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key, .rsaEncryptionPKCS1, plaintext as CFData, &error) as Data? else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw VNCProtocolError.ioError("RSA encryption failed: \(reason)")
        }
        return encrypted
    }

    private static func decrypt(_ ciphertext: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(
            key, .rsaEncryptionPKCS1, ciphertext as CFData, &error) as Data? else {
            error?.release()
            throw VNCProtocolError.authenticationFailed(
                "What the server sent could not be decrypted with the key it was sent to")
        }
        return decrypted
    }

    // MARK: - Encodings

    /// The modulus and exponent of a key in PKCS #1 form: a sequence of two
    /// integers.
    static func parsePublicKey(_ der: Data) -> (modulus: Data, exponent: Data)? {
        var bytes = der[...]
        guard let sequence = readDER(0x30, from: &bytes) else { return nil }
        var contents = sequence
        guard let modulus = readDER(0x02, from: &contents),
              let exponent = readDER(0x02, from: &contents) else { return nil }
        return (Data(modulus.drop(while: { $0 == 0 })), Data(exponent.drop(while: { $0 == 0 })))
    }

    private static func readDER(_ tag: UInt8, from bytes: inout Data.SubSequence) -> Data.SubSequence? {
        guard bytes.popFirst() == tag, let first = bytes.popFirst() else { return nil }
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7f)
            guard count >= 1, count <= 4, bytes.count >= count else { return nil }
            length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
            bytes = bytes.dropFirst(count)
        }
        guard bytes.count >= length else { return nil }
        let value = bytes.prefix(length)
        bytes = bytes.dropFirst(length)
        return value
    }

    static func derInteger(_ magnitude: Data) -> Data {
        var value = Data(magnitude.drop(while: { $0 == 0 }))
        // A first bit that is set would make the number negative.
        if value.first.map({ $0 & 0x80 != 0 }) ?? true {
            value.insert(0, at: value.startIndex)
        }
        return Data([0x02]) + derLength(value.count) + value
    }

    static func derSequence(_ contents: Data) -> Data {
        Data([0x30]) + derLength(contents.count) + contents
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func padded(_ value: Data, to size: Int) -> Data {
        value.count >= size ? Data(value.suffix(size)) : Data(count: size - value.count) + value
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    private static func bigEndian(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private static func uint32(_ data: Data) -> UInt32 {
        data.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func uint16(_ data: Data) -> UInt16 {
        data.reduce(0) { $0 << 8 | UInt16($1) }
    }
}
