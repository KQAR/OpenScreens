import Foundation
import Testing
@testable import OpenScreensCore

@Suite struct ServerIdentityTests {
    private let store = KnownHostsStore.screenSharingServers(fileURL: nil)

    @Test func aCertificateIsKnownByTheFingerprintOpenSSLPrints() {
        // SHA-256 of "abc", as `openssl dgst` and every textbook has it.
        let identity = ServerIdentity.certificate(der: Data("abc".utf8))
        #expect(identity.type == ServerIdentity.certificateType)
        #expect(identity.fingerprint
            == "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
    }

    @Test func aServerKeyShowsItsSignatureAndIsHeldToItsWholeDigest() {
        let one = ServerIdentity.serverKey(
            signature: "01-02-03-04-05-06-07-08", sha256: Data(repeating: 1, count: 32))
        #expect(one.type == ServerIdentity.serverKeyType)
        #expect(one.fingerprint.hasPrefix("01-02-03-04-05-06-07-08 (SHA256:"))
        // The same eight bytes on another key are not the same key.
        let other = ServerIdentity.serverKey(
            signature: "01-02-03-04-05-06-07-08", sha256: Data(repeating: 2, count: 32))
        #expect(one != other)
    }

    @Test func aComputerIsTrustedOnceAndRecognisedAfterwards() throws {
        let identity = ServerIdentity.certificate(der: Data("first".utf8))
        let first = ServerIdentity.challenge(
            host: "pi.local", port: 5900, identity: identity, in: store)
        #expect(first.verdict == .unknown(fingerprint: identity.fingerprint))
        #expect(try first.trust() == .trusted)

        let again = ServerIdentity.challenge(
            host: "PI.local.", port: 5900, identity: identity, in: store)
        #expect(again.verdict == .trusted)
    }

    @Test func anotherCertificateFromTheSameComputerIsAChange() throws {
        let identity = ServerIdentity.certificate(der: Data("first".utf8))
        _ = try ServerIdentity.challenge(
            host: "pi.local", port: 5900, identity: identity, in: store).trust()

        let changed = ServerIdentity.certificate(der: Data("second".utf8))
        let challenge = ServerIdentity.challenge(
            host: "pi.local", port: 5900, identity: changed, in: store)
        #expect(challenge.verdict == .mismatch(
            expected: identity.fingerprint, presented: changed.fingerprint))
    }

    @Test func aKeyWhereACertificateWasTrustedIsAChangeToo() throws {
        // A computer that showed a certificate yesterday and a key today
        // has not been met for the first time.
        let certificate = ServerIdentity.certificate(der: Data("first".utf8))
        _ = try ServerIdentity.challenge(
            host: "pi.local", port: 5900, identity: certificate, in: store).trust()

        let key = ServerIdentity.serverKey(signature: "aa-bb", sha256: Data(repeating: 3, count: 32))
        let challenge = ServerIdentity.challenge(host: "pi.local", port: 5900, identity: key, in: store)
        #expect(challenge.verdict == .mismatch(
            expected: certificate.fingerprint, presented: key.fingerprint))
    }

    @Test func eachPortOfAComputerIsItsOwnServer() throws {
        let identity = ServerIdentity.certificate(der: Data("first".utf8))
        _ = try ServerIdentity.challenge(
            host: "linux.local", port: 5901, identity: identity, in: store).trust()
        let other = ServerIdentity.certificate(der: Data("second".utf8))
        let challenge = ServerIdentity.challenge(
            host: "linux.local", port: 5902, identity: other, in: store)
        #expect(challenge.verdict == .unknown(fingerprint: other.fingerprint))
    }

    @Test func aListThatCannotBeReadSaysWhichListItIs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "TrustedServers.json")
        try Data("not json".utf8).write(to: file)

        let damaged = KnownHostsStore.screenSharingServers(fileURL: file)
        let verdict = damaged.check(
            host: "pi.local", port: 5900, key: ServerIdentity.certificate(der: Data("first".utf8)))
        guard case .storeUnreadable(let reason) = verdict else {
            Issue.record("\(verdict)")
            return
        }
        #expect(reason.contains("trusted screen sharing servers"))
        #expect(!reason.contains("SSH"))
    }
}
