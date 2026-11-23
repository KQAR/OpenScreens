import CryptoKit
import Foundation

/// What a screen sharing server proves it is the same server with, when it
/// protects its connections by itself: the certificate it presents for TLS,
/// or the key an RSA-AES server signs in with.
///
/// Neither is signed by anyone, as a rule, so they are trusted the way an
/// SSH server's key is: shown the first time, remembered, and held to from
/// then on. They are recorded as ``SSHHostKey`` values in a
/// ``KnownHostsStore`` of their own, which brings the same rules with it.
public enum ServerIdentity {
    /// What a certificate is recorded as.
    public static let certificateType = "X.509 certificate"
    /// What an RSA-AES server's key is recorded as.
    public static let serverKeyType = "RSA key"

    /// A certificate, by the SHA-256 fingerprint `openssl x509 -fingerprint
    /// -sha256` prints for it.
    public static func certificate(der: Data) -> SSHHostKey {
        let digest = SHA256.hash(data: der)
        return SSHHostKey(
            type: certificateType,
            fingerprint: digest.map { String(format: "%02X", $0) }.joined(separator: ":"))
    }

    /// An RSA-AES server's key.
    ///
    /// - Parameters:
    ///   - signature: The short form the server itself shows, which is what
    ///     a person compares. It is eight bytes of a SHA-1, too little to
    ///     tell keys apart by when someone is trying to make them alike.
    ///   - sha256: The key's whole SHA-256, which is what is held to.
    public static func serverKey(signature: String, sha256: Data) -> SSHHostKey {
        SSHHostKey(
            type: serverKeyType,
            fingerprint: "\(signature) (SHA256:\(sha256.base64EncodedString().prefix(while: { $0 != "=" })))")
    }

    /// Puts an identity a server presented to `store`, for a decision.
    public static func challenge(
        host: String, port: Int, identity: SSHHostKey, in store: KnownHostsStore
    ) -> SSHHostKeyChallenge {
        SSHHostKeyChallenge(
            host: host, port: port, key: identity,
            verdict: store.check(host: host, port: port, key: identity),
            knownHosts: store)
    }
}
