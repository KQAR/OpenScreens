import Foundation
import RFBProtocol

/// VeNCrypt 0.2. Its X.509-protected subtypes come first. Anonymous TLS
/// subtypes are deliberately not selected because modern TLS stacks no longer
/// support the anonymous cipher suites they require. The subtypes with no TLS
/// at all, which a server such as TigerVNC lists beside the others, are what
/// is left when nothing with a certificate is on offer.
public struct VeNCryptAuthenticator: Authenticator, Sendable {
    private enum Subtype: UInt32, Sendable {
        case none = 1
        case vnc = 2
        case plain = 256
        case x509None = 260
        case x509VNC = 261
        case x509Plain = 262

        var usesTLS: Bool { rawValue >= 260 }
    }

    /// The anonymous TLS subtypes, which cannot be used.
    private static let anonymousTLS: Set<UInt32> = [257, 258, 259]

    private let host: String
    private let port: UInt16
    private let username: String?
    private let password: String
    private let certificateValidationHandler: VNCCertificateValidationHandler?
    /// Whether only a subtype inside TLS will do.
    private let requiresTLS: Bool
    private let log = VNCLogger(category: "VeNCrypt")

    public init(
        host: String,
        port: UInt16,
        username: String?,
        password: String,
        certificateValidationHandler: VNCCertificateValidationHandler? = nil,
        requiresTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.certificateValidationHandler = certificateValidationHandler
        self.requiresTLS = requiresTLS
    }

    public func authenticate(connection: any RFBConnection) async throws -> AuthenticationResult {
        let canUseTLS = await connection.supportsTLSUpgrade()

        let serverVersion = try await connection.read(exactly: 2)
        guard serverVersion.count == 2,
              serverVersion[serverVersion.startIndex] == 0,
              serverVersion[serverVersion.startIndex + 1] >= 2 else {
            throw VNCProtocolError.protocolViolation(
                "Unsupported VeNCrypt version \(serverVersion.map(String.init).joined(separator: "."))")
        }
        // VeNCrypt 0.2 is the interoperable version implemented by TigerVNC,
        // x11vnc, and wayvnc.
        try await connection.send(Data([0, 2]))
        let versionStatus = try await connection.read(exactly: 1)
        guard versionStatus.first == 0 else {
            throw VNCProtocolError.authenticationFailed(
                "The server rejected VeNCrypt 0.2")
        }

        let subtypeCountData = try await connection.read(exactly: 1)
        guard let countByte = subtypeCountData.first, countByte > 0 else {
            throw VNCProtocolError.authenticationFailed(
                "The server offered no VeNCrypt security subtypes")
        }
        let subtypeData = try await connection.read(exactly: Int(countByte) * 4)
        var offered: [UInt32] = []
        for offset in stride(from: 0, to: subtypeData.count, by: 4) {
            let byte0 = UInt32(subtypeData[offset]) << 24
            let byte1 = UInt32(subtypeData[offset + 1]) << 16
            let byte2 = UInt32(subtypeData[offset + 2]) << 8
            let byte3 = UInt32(subtypeData[offset + 3])
            offered.append(byte0 | byte1 | byte2 | byte3)
        }
        guard let selected = selectSubtype(from: offered, canUseTLS: canUseTLS) else {
            throw VNCProtocolError.authenticationFailed(
                whyNothingWasSelected(from: offered, canUseTLS: canUseTLS))
        }

        try await connection.send(Self.bigEndianData(selected.rawValue))
        log.info("Selected VeNCrypt subtype \(selected.rawValue)")
        // VeNCrypt 0.2 acknowledges the selection with one byte (1 = accepted)
        // before the TLS handshake; it must be consumed so the handshake
        // starts at the server's ServerHello.
        let subtypeStatus = try await connection.read(exactly: 1)
        guard subtypeStatus.first == 1 else {
            throw VNCProtocolError.authenticationFailed(
                "The server rejected VeNCrypt subtype \(selected.rawValue)")
        }
        if selected.usesTLS {
            try await connection.startTLS(configuration: RFBTLSConfiguration(
                serverHostname: host,
                serverPort: port,
                certificateValidationHandler: certificateValidationHandler))
        }

        switch selected {
        case .none, .x509None:
            break
        case .vnc, .x509VNC:
            _ = try await VNCAuthenticator(password: password)
                .authenticate(connection: connection)
        case .plain, .x509Plain:
            try await sendPlainCredentials(connection: connection)
        }
        return AuthenticationResult(establishedTLS: selected.usesTLS)
    }

    private var hasUsername: Bool {
        username.map { !$0.isEmpty } ?? false
    }

    private func selectSubtype(from offered: [UInt32], canUseTLS: Bool) -> Subtype? {
        // With a user name, a sign-in that takes one; without, one that
        // does not. Inside TLS before outside it.
        var wanted: [Subtype] = []
        if canUseTLS {
            wanted += hasUsername ? [.x509Plain, .x509VNC, .x509None] : [.x509VNC, .x509None]
        }
        if !requiresTLS {
            wanted += hasUsername ? [.plain, .vnc, .none] : [.vnc, .none]
        }
        return wanted.first { offered.contains($0.rawValue) }
    }

    /// What to say when the server offered nothing that could be selected.
    private func whyNothingWasSelected(from offered: [UInt32], canUseTLS: Bool) -> String {
        let plainSubtypes = [Subtype.x509Plain, .plain].filter {
            ($0.usesTLS ? canUseTLS : !requiresTLS) && offered.contains($0.rawValue)
        }
        if !hasUsername, !plainSubtypes.isEmpty {
            return VNCProtocolError.usernameRequiredReason
        }
        if !canUseTLS, offered.contains(where: { $0 >= 260 }) {
            return "This server protects its connections with TLS, which cannot be used through a tunnel"
        }
        if offered.allSatisfy({ Self.anonymousTLS.contains($0) }) {
            return "This server only offers TLS without a certificate, which is not supported"
        }
        let list = offered.map(String.init).joined(separator: ", ")
        return "The server offered no VeNCrypt sign-in that is supported (\(list))"
    }

    private func sendPlainCredentials(connection: any RFBConnection) async throws {
        let usernameData = Data((username ?? "").utf8)
        let passwordData = Data(password.utf8)
        guard usernameData.count <= Int(UInt32.max),
              passwordData.count <= Int(UInt32.max) else {
            throw VNCProtocolError.authenticationFailed(
                "VeNCrypt credentials are too long")
        }
        var payload = Data()
        payload.append(Self.bigEndianData(UInt32(usernameData.count)))
        payload.append(Self.bigEndianData(UInt32(passwordData.count)))
        payload.append(usernameData)
        payload.append(passwordData)
        try await connection.send(payload)
    }

    private static func bigEndianData(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }
}
