import Foundation
import Network
import Observation
#if canImport(TailscaleKit)
import TailscaleKit
#endif

/// How to reach a computer in the tailnet through the app's own node.
public struct TailnetRoute: Sendable {
    /// The computer's Tailscale address, to dial in place of the name the
    /// user gave: the node resolves nothing for the system.
    public var host: String
    /// The node's SOCKS5 server, credentials applied.
    public var proxy: ProxyConfiguration
}

/// A Tailscale node running inside the iPhone and iPad app, so computers in
/// a tailnet can be listed and reached without the Tailscale app and its VPN.
///
/// The node is userspace: it owns no network interface and changes no
/// routes, so it neither needs the VPN permission nor gets in the way of the
/// Tailscale app's VPN. It joins the tailnet as a device of its own. Its
/// connections leave through a SOCKS5 server on loopback that only the
/// connections to its peers are pointed at (``route(to:)``).
///
/// Its login lives in the app's data directory and survives relaunches. When
/// the app is suspended the node stops with it; iOS may also take back the
/// loopback listener in the meantime, so ``resume()`` checks it and starts the
/// node again from its saved state when it is gone.
///
/// On the Mac there is no node: the installed Tailscale client already
/// reaches the tailnet, and everything here stays signed out.
@MainActor
@Observable
public final class EmbeddedTailnet {
    public static let shared = EmbeddedTailnet()

    public enum State: Equatable, Sendable {
        /// No login saved.
        case signedOut
        /// The node is starting, from a saved login or to ask for one.
        case starting
        /// The node is waiting for someone to sign in: for the first time, or
        /// again once its key has expired. The address to do it at, once
        /// Tailscale has handed one out; ``signIn()`` asks for one.
        case needsLogin(URL?)
        /// Signed in, waiting for an admin of the tailnet to approve the
        /// device. Moves on to ``running(tailnet:)`` by itself.
        case awaitingApproval
        /// Signed in to the named tailnet and connected.
        case running(tailnet: String)
        case failed(String)
    }

    public private(set) var state: State = .signedOut

    /// Whether this build has a node to run.
    public nonisolated static var isSupported: Bool {
        #if canImport(TailscaleKit)
        true
        #else
        false
        #endif
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether a login is saved, running or not.
    public var hasSavedLogin: Bool {
        FileManager.default.fileExists(atPath: Self.stateFile.path)
    }

    /// Whether the saved login has ever got as far as running, which tells
    /// an expired key from a first sign-in that was never finished.
    public var hasBeenSignedIn: Bool {
        FileManager.default.fileExists(atPath: Self.signedInMarker.path)
    }

    private nonisolated static var signedInMarker: URL {
        directory.appending(path: "signed-in")
    }

    nonisolated static var directory: URL {
        StorageLocation.baseDirectory.appending(path: "Tailscale", directoryHint: .isDirectory)
    }

    private nonisolated static var stateFile: URL {
        directory.appending(path: "tailscaled.state")
    }

    /// The status last read from the node, for telling its peers from other
    /// hosts without waiting.
    @ObservationIgnored private var lastStatus: TailscaleLocalStatus?

    #if canImport(TailscaleKit)
    @ObservationIgnored private var node: TailscaleNode?
    @ObservationIgnored private var loopback: TailscaleNode.LoopbackConfig?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    #endif

    init() {}

    // MARK: - Signing in and out

    /// Starts the node, which asks for a login when none is saved, or asks a
    /// running node that needs one for a new sign-in address. Watch
    /// ``state`` for the address to sign in at.
    public func signIn() async {
        #if canImport(TailscaleKit)
        guard node != nil else {
            start()
            return
        }
        if let loopback = await liveLoopback() {
            await Self.localAPI("login-interactive", loopback: loopback)
        }
        #endif
    }

    /// Starts the node from its saved login, or checks that a running one can
    /// still be reached after the app was in the background.
    public func resume() async {
        #if canImport(TailscaleKit)
        guard hasSavedLogin else { return }
        guard node != nil else {
            start()
            return
        }
        if let loopback, await !Self.isListening(loopback) {
            // Taken back by the system while the app was suspended.
            await stopNode()
            start()
        }
        #endif
    }

    /// Signs the node out of the tailnet and forgets its login. Also ends a
    /// sign-in that is under way.
    public func signOut() async {
        #if canImport(TailscaleKit)
        if let loopback {
            // Best effort: the device leaves the admin console's list at
            // once instead of lingering as offline.
            await Self.localAPI("logout", loopback: loopback)
        }
        await stopNode()
        #endif
        try? FileManager.default.removeItem(at: Self.directory)
        lastStatus = nil
        state = .signedOut
    }

    // MARK: - Devices and routes

    /// The devices in the tailnet, this one included, as the node sees them.
    public func devices() async throws -> [TailscaleDevice] {
        // A node starting from its saved login runs within seconds; list
        // then rather than report it as not running.
        for _ in 0..<20 where state == .starting {
            try await Task.sleep(for: .milliseconds(500))
        }
        let status = try await readStatus()
        return try status.devices()
    }

    /// Whether `host` names a device in the tailnet as last seen, without
    /// asking the node. A session decides with this whether to go through
    /// the node at all.
    public func reaches(_ host: String) -> Bool {
        isRunning && lastStatus.flatMap { Self.peerAddress(for: host, in: $0) } != nil
    }

    /// The way to `host` through the node, or `nil` when `host` is not a
    /// device in the tailnet or the node is not running. Everything else
    /// keeps connecting the way it always has.
    public func route(to host: String) async -> TailnetRoute? {
        #if canImport(TailscaleKit)
        guard isRunning, let status = try? await readStatus(),
              let address = Self.peerAddress(for: host, in: status) else { return nil }
        guard let loopback = await liveLoopback(),
              let port = loopback.port.flatMap({ NWEndpoint.Port(rawValue: UInt16(clamping: $0)) })
        else { return nil }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
        proxy.allowFailover = false
        proxy.applyCredential(username: "tsnet", password: loopback.proxyCredential)
        return TailnetRoute(host: address, proxy: proxy)
        #else
        return nil
        #endif
    }

    /// The peer's address to dial when `host` is its address, its MagicDNS
    /// name, the first label of that name, or its host name.
    nonisolated static func peerAddress(for host: String, in status: TailscaleLocalStatus) -> String? {
        let wanted = TailscaleDevice.trimmedDNSName(host).lowercased()
        guard !wanted.isEmpty else { return nil }
        for entry in (status.peers ?? [:]).values {
            guard let node = entry.value else { continue }
            let addresses = TailscaleDevice.orderedAddresses(node.tailscaleIPs)
            let dnsName = TailscaleDevice.trimmedDNSName(node.dnsName).lowercased()
            let names = [
                dnsName,
                dnsName.split(separator: ".").first.map(String.init) ?? "",
                (node.hostName ?? "").lowercased(),
            ]
            if addresses.map({ $0.lowercased() }).contains(wanted)
                || names.contains(where: { !$0.isEmpty && $0 == wanted }) {
                return addresses.first
            }
        }
        return nil
    }

    // MARK: - The node

    private func readStatus() async throws -> TailscaleLocalStatus {
        #if canImport(TailscaleKit)
        guard let node else { throw TailscaleError.notRunning }
        let data = try await node.statusJSON()
        let status = try JSONDecoder().decode(TailscaleLocalStatus.self, from: data)
        apply(status)
        return status
        #else
        throw TailscaleError.notInstalled
        #endif
    }

    private func apply(_ status: TailscaleLocalStatus) {
        lastStatus = status
        switch status.backendState {
        case "Running":
            state = .running(tailnet: status.currentTailnet?.name ?? "")
            if !hasBeenSignedIn {
                FileManager.default.createFile(atPath: Self.signedInMarker.path, contents: nil)
            }
        case "NeedsLogin":
            // An expired key also lands here, without an address until one
            // is asked for.
            state = .needsLogin(status.authURL.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        case "NeedsMachineAuth":
            state = .awaitingApproval
        default:
            break
        }
    }

    #if canImport(TailscaleKit)
    private func start() {
        state = .starting
        let directory = Self.directory
        watcher = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // The node's keys are this device's alone; a backup restored
                // onto another must sign in afresh rather than share them.
                var url = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? url.setResourceValues(values)
                let node = try await Self.makeNode(in: directory)
                guard let self else { return }
                self.node = node
                self.loopback = try await node.loopback()
                await self.watch()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Follows the node's state: quickly while it starts or waits for a
    /// login, slowly once it runs, so ``reaches(_:)`` stays current.
    private func watch() async {
        while !Task.isCancelled {
            _ = try? await readStatus()
            let pause: Duration = switch state {
            case .running: .seconds(30)
            // An admin may take a while; there is no hurry to notice.
            case .awaitingApproval: .seconds(5)
            default: .seconds(1)
            }
            try? await Task.sleep(for: pause)
        }
    }

    @concurrent
    private static func makeNode(in directory: URL) async throws -> TailscaleNode {
        #if os(iOS)
        let model = await UIDeviceModel.name
        #else
        let model = "Mac"
        #endif
        let config = Configuration(
            hostName: "OpenScreens-\(model)",
            path: directory.path,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: false)
        // tailscale_start returns once the node is set up; the login itself
        // happens in the background and shows in the status.
        return try TailscaleNode(config: config, logger: FileLog())
    }

    private func stopNode() async {
        watcher?.cancel()
        watcher = nil
        loopback = nil
        if let node {
            self.node = nil
            try? await node.close()
        }
    }

    /// The loopback server, started again with the node if the system took
    /// it back while the app was suspended.
    private func liveLoopback() async -> TailscaleNode.LoopbackConfig? {
        guard let loopback else { return nil }
        if await Self.isListening(loopback) { return loopback }
        await stopNode()
        start()
        // Wait out the restart: a saved login is back within seconds.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if state != .starting, let fresh = self.loopback { return fresh }
        }
        return nil
    }

    /// Any answer from the loopback server proves it still listens.
    private nonisolated static func isListening(_ loopback: TailscaleNode.LoopbackConfig) async -> Bool {
        guard let url = URL(string: "http://\(loopback.address)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private nonisolated static func localAPI(_ endpoint: String, loopback: TailscaleNode.LoopbackConfig) async {
        guard let url = URL(string: "http://\(loopback.address)/localapi/v0/\(endpoint)") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        let credential = Data(":\(loopback.localAPIKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
    #endif
}

#if canImport(TailscaleKit)
/// The node's own log, kept beside its state and started afresh with each
/// launch: the place to look when it will not connect.
private struct FileLog: LogSink {
    /// One file for every node the process starts.
    private static let fd: Int32 = open(
        EmbeddedTailnet.directory.appending(path: "tailscale.log").path,
        O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)

    var logFileHandle: Int32? { Self.fd >= 0 ? Self.fd : nil }

    func log(_ message: String) {}
}
#endif

#if os(iOS)
import UIKit

private enum UIDeviceModel {
    /// "iPhone" or "iPad": the device's own name needs an entitlement.
    @MainActor static var name: String { UIDevice.current.model }
}
#endif

/// Lists devices through ``EmbeddedTailnet``.
struct EmbeddedTailnetSource: TailscaleSource {
    func devices() async throws -> [TailscaleDevice] {
        try await EmbeddedTailnet.shared.devices()
    }
}
