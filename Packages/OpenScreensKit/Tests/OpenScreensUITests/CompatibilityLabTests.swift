import CoreGraphics
import Foundation
import ImageIO
import OpenScreensCore
import Testing
@testable import OpenScreensUI

/// The servers of `scripts/compat-lab`: TigerVNC, x11vnc and wayvnc, set up
/// the ways people set them up. Each test opens a real session to one of
/// them and then looks inside the lab at what arrived there.
///
/// The lab is a container that has to be running, so these tests are skipped
/// unless `OPENSCREENS_COMPAT_LAB` is set. `scripts/compat-lab/lab.sh test`
/// starts the lab and runs them.
nonisolated enum CompatibilityLab {
    static let isUp = ProcessInfo.processInfo.environment["OPENSCREENS_COMPAT_LAB"] != nil
    static let host = "127.0.0.1"
    static let container = "openscreens-compat-lab"
    static let password = "secret12"
    static let user = "demo"
    static let userPassword = "demo-secret"

    /// What a server shares, which decides how to look at it from inside.
    enum Desktop: Sendable {
        /// An X display, by number.
        case x11(Int)
        /// A Wayland session, by the name of its runtime directory.
        case wayland(String)

        var environment: [String] {
            switch self {
            case .x11(let number):
                ["DISPLAY=:\(number)"]
            case .wayland(let name):
                ["XDG_RUNTIME_DIR=/tmp/wayland-\(name)", "WAYLAND_DISPLAY=wayland-1"]
            }
        }
    }

    struct Server: Sendable, CustomTestStringConvertible {
        var name: String
        var port: Int
        var desktop: Desktop
        var username: String?
        var password: String?
        /// Whether the server shows a certificate nobody has signed.
        var selfSigned = false
        /// Whether the server signs in with a key of its own (RSA-AES).
        var presentsKey = false
        /// Whether text other than Latin-1 survives the clipboard. It takes
        /// the clipboard extension TigerVNC introduced, which x11vnc lacks.
        var clipboardIsUnicode = true
        /// Where the server writes down the text it is sent, when asking
        /// the desktop for it does not work. x11vnc keeps what it is sent
        /// to itself until something pastes, and in a display with nothing
        /// but a terminal in it does not pass on what is copied there, so
        /// what it took is read from its log and the other direction is
        /// left untested.
        var clipboardLog: String?
        /// Whether the server lets a client change the size of its desktop.
        var resizes = true
        /// What the statistics should say protects the session.
        var encryption: String?

        var testDescription: String { "\(name) (\(port))" }
    }

    /// The servers to test: all of them, or the ones whose ports are listed
    /// in `OPENSCREENS_COMPAT_LAB_PORTS`, as in `5901,5922`.
    static let servers: [Server] = {
        let ports = (ProcessInfo.processInfo.environment["OPENSCREENS_COMPAT_LAB_PORTS"] ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return ports.isEmpty ? allServers : allServers.filter { ports.contains($0.port) }
    }()

    static let allServers: [Server] = [
        Server(name: "TigerVNC, VNC password", port: 5901, desktop: .x11(1),
               password: password),
        Server(name: "TigerVNC, as installed", port: 5902, desktop: .x11(2),
               password: password),
        Server(name: "TigerVNC, TLS and a VNC password", port: 5903, desktop: .x11(3),
               password: password, selfSigned: true, encryption: "TLS"),
        Server(name: "TigerVNC, TLS and a user name", port: 5904, desktop: .x11(4),
               username: user, password: userPassword, selfSigned: true, encryption: "TLS"),
        Server(name: "TigerVNC, RSA-AES", port: 5905, desktop: .x11(5),
               password: password, presentsKey: true, encryption: "AES-128"),
        Server(name: "TigerVNC, RSA-AES-256 and a user name", port: 5906, desktop: .x11(6),
               username: user, password: userPassword, presentsKey: true, encryption: "AES-256"),
        Server(name: "TigerVNC, RSA-AES for sign-in only", port: 5907, desktop: .x11(7),
               password: password, presentsKey: true),
        Server(name: "TigerVNC, no sign-in", port: 5908, desktop: .x11(8)),
        Server(name: "x11vnc, VNC password", port: 5911, desktop: .x11(11),
               password: password, clipboardIsUnicode: false,
               clipboardLog: "/lab/x11vnc-11.log", resizes: false),
        Server(name: "x11vnc, TLS and a VNC password", port: 5912, desktop: .x11(12),
               password: password, selfSigned: true, clipboardIsUnicode: false,
               clipboardLog: "/lab/x11vnc-12.log", resizes: false, encryption: "TLS"),
        Server(name: "wayvnc, no sign-in", port: 5921, desktop: .wayland("open")),
        Server(name: "wayvnc, as Raspberry Pi OS sets it up", port: 5922, desktop: .wayland("pi"),
               username: user, password: userPassword, presentsKey: true, encryption: "AES-256"),
    ]

    /// The servers that have to be vouched for before a session opens.
    static let serversToVouchFor = servers.filter { $0.selfSigned || $0.presentsKey }
    static let serversWithUsers = servers.filter { $0.username != nil }

    /// Runs a command inside the lab and returns what it printed.
    @discardableResult
    static func run(_ desktop: Desktop, _ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        var arguments = ["docker", "exec"]
        for variable in desktop.environment {
            arguments += ["--env", variable]
        }
        arguments += [container, "bash", "-c", command]
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite(.serialized, .enabled(if: CompatibilityLab.isUp))
struct CompatibilityLabTests {
    typealias Server = CompatibilityLab.Server

    private func makeModel() throws -> AppModel {
        let suite = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensLab-\(UUID().uuidString)").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppModel(
            library: LibraryStore(fileURL: nil, backupsDirectory: nil),
            settings: AppSettings(defaults: defaults),
            credentials: CredentialStore(storage: InMemorySecretStorage()))
    }

    private func open(
        _ server: Server,
        in existing: AppModel? = nil,
        configure: (inout Computer) -> Void = { _ in }
    ) throws -> (RemoteSession, AppModel) {
        let model = try existing ?? makeModel()
        var computer = Computer(
            name: server.name, host: CompatibilityLab.host, port: server.port,
            username: server.username, kind: .linux, settings: .defaults(for: .linux))
        // The lab has no business with the clipboard of whoever runs it:
        // these tests hand the engine text of their own instead.
        computer.settings.sharedClipboard = false
        computer.settings.reconnectAutomatically = false
        configure(&computer)
        computer = model.library.add(computer)
        if let password = server.password {
            try model.credentials.setPassword(password, for: computer.id)
        }
        let session = model.sessions.open(computer)
        session.viewport.viewSize = CGSize(width: 1280, height: 800)
        return (session, model)
    }

    private func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Connects, answering for a certificate the way someone who has
    /// checked it would.
    private func connect(_ session: RemoteSession) async -> Bool {
        session.start()
        return await waitUntil {
            if case .awaitingHostKey = session.phase {
                session.answerHostKey(trust: true)
            }
            switch session.phase {
            case .connected, .failed, .awaitingCredentials: return true
            default: return false
            }
        }
    }

    @Test(arguments: CompatibilityLab.servers)
    func aSessionOpensAndShowsTheDesktop(_ server: Server) async throws {
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        #expect(session.phase == .connected, "\(session.phase)")
        guard session.phase == .connected else { return }

        #expect(await waitUntil { session.remoteSize == CGSize(width: 1280, height: 800) },
                "\(session.remoteSize)")
        #expect(await waitUntil { session.screenshot() != nil })
        // The lab's desktops are one colour away from the terminal.
        let arrived = await waitUntil {
            guard let image = session.screenshot(), let pixels = Pixels(image) else { return false }
            return pixels.isClose(to: (0x2f, 0x6f, 0x9f), atX: 1200, y: 700, tolerance: 12)
        }
        #expect(arrived, "the desktop's colour did not arrive")
        if !arrived, let directory = ProcessInfo.processInfo.environment["OPENSCREENS_COMPAT_LAB_DUMP"],
           let image = session.screenshot() {
            // What did arrive, for whoever is looking into it.
            let url = URL(fileURLWithPath: directory).appending(path: "\(server.port).png")
            if let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    @Test(arguments: CompatibilityLab.servers)
    func whatIsTypedArrives(_ server: Server) async throws {
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        guard session.phase == .connected else {
            Issue.record("\(session.phase)")
            return
        }
        _ = await waitUntil { session.screenshot() != nil }

        // The terminal has the keyboard while the pointer is over it.
        session.pointer(buttons: [], at: CGPoint(x: 300, y: 200))
        try await Task.sleep(for: .milliseconds(300))
        let file = "/tmp/typed-\(server.port)"
        CompatibilityLab.run(server.desktop, "rm -f \(file)")
        // Letters in both cases, digits, and the punctuation a shell needs:
        // a server gets key symbols and has to find the keys for them.
        let text = "Typed_By-OpenScreens 2026 {a|b} [c] <d> ~e #f @g $h %i ^j &k *l (m) +n =o ;p :q ,r .s ?t !u"
        session.type("printf '%s' '\(text)' > \(file)\n")
        var typed = ""
        let matches = await waitUntil(timeout: .seconds(10)) {
            typed = CompatibilityLab.run(server.desktop, "cat \(file) 2>/dev/null")
            return typed == text
        }
        #expect(matches, "arrived as: \(typed)")
    }

    @Test(arguments: CompatibilityLab.servers)
    func thePointerArrivesWhereItWasPut(_ server: Server) async throws {
        guard case .x11 = server.desktop else { return }
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        guard session.phase == .connected else {
            Issue.record("\(session.phase)")
            return
        }
        session.pointer(buttons: [], at: CGPoint(x: 777, y: 555))
        var location = ""
        let arrived = await waitUntil(timeout: .seconds(5)) {
            location = CompatibilityLab.run(server.desktop, "xdotool getmouselocation")
            return location.hasPrefix("x:777 y:555 ")
        }
        #expect(arrived, "the pointer is at: \(location)")
    }

    @Test(arguments: CompatibilityLab.servers)
    func textCopiedHereCanBePastedThere(_ server: Server) async throws {
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        guard session.phase == .connected else {
            Issue.record("\(session.phase)")
            return
        }
        _ = await waitUntil { session.screenshot() != nil }
        let text = server.clipboardIsUnicode
            ? "Copied here, pasted there: çğış €" : "Copied here, pasted there"
        session.engine.sendClipboardText(text)
        let paste = if let log = server.clipboardLog {
            "grep -o \"Set CLIPBOARD *'.*'\" \(log) | tail -1 | sed \"s/^Set CLIPBOARD *'//; s/'$//\""
        } else {
            switch server.desktop {
            case .x11: "timeout 2 xclip -o -selection clipboard 2>/dev/null"
            case .wayland: "timeout 2 wl-paste --no-newline 2>/dev/null"
            }
        }
        var pasted = ""
        let arrived = await waitUntil(timeout: .seconds(8)) {
            pasted = CompatibilityLab.run(server.desktop, paste)
            return pasted == text
        }
        #expect(arrived, "pasted as: \(pasted)")
    }

    @Test(arguments: CompatibilityLab.servers.filter { $0.clipboardLog == nil })
    func textCopiedThereArrivesHere(_ server: Server) async throws {
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        var received: [String] = []
        session.engine.onServerClipboardText = { received.append($0) }
        _ = await connect(session)
        guard session.phase == .connected else {
            Issue.record("\(session.phase)")
            return
        }
        _ = await waitUntil { session.screenshot() != nil }
        // What the app does when the shared clipboard is on, without the
        // clipboard of whoever is running this.
        session.engine.setRemoteSharedClipboardEnabled(true)
        try await Task.sleep(for: .milliseconds(300))
        let text = (server.clipboardIsUnicode ? "Copied there: çğış € " : "Copied there: ")
            + "\(server.port)"
        let copy = switch server.desktop {
        case .x11: "printf '%s' '\(text)' | xclip -i -selection clipboard -loops 0 >/dev/null 2>&1 &"
        case .wayland: "printf '%s' '\(text)' | wl-copy >/dev/null 2>&1 &"
        }
        CompatibilityLab.run(server.desktop, copy)
        let arrived = await waitUntil(timeout: .seconds(8)) { received.contains(text) }
        #expect(arrived, "received: \(received)")
    }

    @Test(arguments: CompatibilityLab.servers.filter(\.resizes))
    func theDesktopIsMadeTheSizeOfTheWindow(_ server: Server) async throws {
        let (session, model) = try open(server) { $0.settings.resolution = .matchWindow }
        defer {
            // Put back for the tests after this one.
            switch server.desktop {
            case .x11:
                CompatibilityLab.run(server.desktop, "xrandr --fb 1280x800 2>/dev/null; xrandr -s 1280x800 2>/dev/null")
            case .wayland:
                CompatibilityLab.run(
                    server.desktop,
                    "swaymsg -s \"$(ls $XDG_RUNTIME_DIR/sway-ipc.*.sock | head -1)\" "
                        + "output HEADLESS-1 resolution 1280x800 2>/dev/null")
            }
            model.sessions.close(session)
        }
        _ = await connect(session)
        guard session.phase == .connected else {
            Issue.record("\(session.phase)")
            return
        }
        _ = await waitUntil { session.screenshot() != nil }
        session.viewDidResize(to: CGSize(width: 1000, height: 700), displayScale: 1)
        let resized = await waitUntil(timeout: .seconds(8)) {
            session.remoteSize == CGSize(width: 1000, height: 700)
        }
        #expect(resized, "the desktop is \(session.remoteSize)")

        // A window of another size, as when it is dragged or a phone turned.
        session.viewDidResize(to: CGSize(width: 700, height: 1000), displayScale: 1)
        let turned = await waitUntil(timeout: .seconds(8)) {
            session.remoteSize == CGSize(width: 720, height: 1028)
        }
        #expect(turned, "the desktop is \(session.remoteSize)")

        // Leaving the desktop alone again puts it back as it was found.
        session.update { $0.resolution = .remote }
        let restored = await waitUntil(timeout: .seconds(8)) {
            session.remoteSize == CGSize(width: 1280, height: 800)
        }
        #expect(restored, "the desktop is \(session.remoteSize)")
    }

    @Test(arguments: CompatibilityLab.servers)
    func theSessionSaysHowItIsProtected(_ server: Server) async throws {
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        guard session.phase == .connected else {
            Issue.record("\(session.phase)")
            return
        }
        session.setStatisticsActive(true)
        let known = await waitUntil(timeout: .seconds(5)) { session.statistics != nil }
        #expect(known)
        let expected = server.encryption ?? "Screen not encrypted"
        #expect(session.statistics?.encryption == expected)
    }

    /// Waits for the session to ask about the server's certificate or key.
    private func identityPrompt(_ session: RemoteSession) async -> RemoteSession.HostKeyPrompt? {
        session.start()
        var prompt: RemoteSession.HostKeyPrompt?
        _ = await waitUntil {
            switch session.phase {
            case .awaitingHostKey(let asked):
                prompt = asked
                return true
            case .connected, .failed, .awaitingCredentials:
                return true
            default:
                return false
            }
        }
        return prompt
    }

    @Test(arguments: CompatibilityLab.serversToVouchFor)
    func aComputerIsVouchedForOnceAndRememberedAfterwards(_ server: Server) async throws {
        let model = try makeModel()
        let (first, _) = try open(server, in: model)
        let prompt = try #require(await identityPrompt(first), "\(first.phase)")
        #expect(prompt.subject == (server.presentsKey ? .serverKey : .certificate))
        #expect(!prompt.keyHasChanged)
        #expect(prompt.host == CompatibilityLab.host)
        #expect(prompt.port == server.port)
        #expect(!prompt.fingerprint.isEmpty)
        first.answerHostKey(trust: true)
        #expect(await waitUntil { first.phase == .connected }, "\(first.phase)")
        model.sessions.close(first)

        // The next session has nothing to ask.
        let (second, _) = try open(server, in: model)
        defer { model.sessions.close(second) }
        #expect(await identityPrompt(second) == nil)
        #expect(await waitUntil { second.phase == .connected }, "\(second.phase)")
    }

    @Test(arguments: CompatibilityLab.serversToVouchFor)
    func aComputerThatIsNotVouchedForIsNotConnectedTo(_ server: Server) async throws {
        let (session, model) = try open(server)
        defer { model.sessions.close(session) }
        _ = try #require(await identityPrompt(session), "\(session.phase)")
        session.answerHostKey(trust: false)
        var message = ""
        let stopped = await waitUntil {
            if case .failed(let reason) = session.phase {
                message = reason
                return true
            }
            return false
        }
        #expect(stopped, "\(session.phase)")
        // Said as what it is, and not as a password that was wrong.
        #expect(message.contains("was not trusted"), "\(message)")
        #expect(try model.trustedServers.all().isEmpty)
    }

    @Test(arguments: CompatibilityLab.serversToVouchFor)
    func aComputerThatPresentsSomethingElseIsShownAsChanged(_ server: Server) async throws {
        let model = try makeModel()
        let type = server.presentsKey ? ServerIdentity.serverKeyType : ServerIdentity.certificateType
        try model.trustedServers.trust(
            host: CompatibilityLab.host, port: server.port,
            key: SSHHostKey(type: type, fingerprint: "what it was before"))
        let (session, _) = try open(server, in: model)
        defer { model.sessions.close(session) }
        let prompt = try #require(await identityPrompt(session), "\(session.phase)")
        #expect(prompt.keyHasChanged)
        #expect(prompt.expectedFingerprint == "what it was before")

        // Accepting it puts the new one in place of the old.
        session.answerHostKey(trust: true)
        #expect(await waitUntil { session.phase == .connected }, "\(session.phase)")
        let recorded = try model.trustedServers.all()
        #expect(recorded.count == 1)
        #expect(recorded.first?.keys.map(\.fingerprint) == [prompt.fingerprint])
    }

    @Test(arguments: CompatibilityLab.serversWithUsers)
    func aServerThatWantsAUserNameAsksForOne(_ server: Server) async throws {
        var nameless = server
        nameless.username = nil
        let (session, model) = try open(nameless)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        guard case .awaitingCredentials(let prompt) = session.phase else {
            Issue.record("\(session.phase)")
            return
        }
        #expect(prompt.asksForUsername)

        session.submitCredentials(
            username: try #require(server.username), password: try #require(server.password),
            remember: false)
        let connected = await waitUntil {
            if case .awaitingHostKey = session.phase {
                session.answerHostKey(trust: true)
            }
            return session.phase == .connected
        }
        #expect(connected, "\(session.phase)")
        // The name is kept with the computer for the next time.
        #expect(session.computer.username == server.username)
    }

    @Test(arguments: CompatibilityLab.servers.filter { $0.password != nil })
    func aWrongPasswordIsAskedForAgain(_ server: Server) async throws {
        var wrong = server
        wrong.password = "not-this"
        let (session, model) = try open(wrong)
        defer { model.sessions.close(session) }
        _ = await connect(session)
        guard case .awaitingCredentials(let prompt) = session.phase else {
            Issue.record("\(session.phase)")
            return
        }
        #expect(prompt.message != nil)
        #expect(prompt.asksForUsername == (server.username != nil))
    }
}

/// Reads pixels out of a picture.
private struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.data = data
    }

    func isClose(to colour: (Int, Int, Int), atX x: Int, y: Int, tolerance: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        let offset = (y * width + x) * 4
        return abs(Int(data[offset]) - colour.0) <= tolerance
            && abs(Int(data[offset + 1]) - colour.1) <= tolerance
            && abs(Int(data[offset + 2]) - colour.2) <= tolerance
    }
}
