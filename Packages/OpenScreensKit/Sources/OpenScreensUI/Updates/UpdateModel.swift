import Foundation
import Observation
import OpenScreensCore

/// What the user chose to do about an update.
public enum UpdateChoice: Sendable {
    case install
    /// Not now: say so again later.
    case later
    /// Never, for this version.
    case skip
}

/// Whatever finds updates, downloads them and puts them in place.
///
/// The Mac app has one, built on Sparkle. On iPhone and iPad updates are the
/// App Store's and TestFlight's to deliver, and there is none.
public protocol UpdateEngine: AnyObject {
    var checksAutomatically: Bool { get set }
    /// Whether an update that was found is downloaded and installed without
    /// asking, the next time the app quits.
    var installsAutomatically: Bool { get set }
    var lastCheckDate: Date? { get }

    /// Looks for an update because the user asked.
    func check()
    /// Answers the question the engine last put: whether to install what it
    /// found, or what it has ready.
    func respond(_ choice: UpdateChoice)
    /// Stops a check or a download that is under way.
    func cancel()
    /// The user has seen that there is nothing newer, or what went wrong.
    func acknowledge()
}

/// Where an update stands, for the interface to show.
///
/// The engine moves it along; the interface only reads it and passes on what
/// the user chooses.
@Observable
public final class UpdateModel {

    /// A version that can be installed in place of this one.
    public struct Release: Equatable, Sendable {
        public var version: String
        public var build: String
        public var notes: ReleaseNotes
        public var date: Date?
        /// The size of what is downloaded. Zero when the feed does not say.
        public var byteCount: UInt64
        /// Whether its author marked it as one not to put off.
        public var isCritical: Bool

        public init(
            version: String, build: String, notes: ReleaseNotes = ReleaseNotes(blocks: []),
            date: Date? = nil, byteCount: UInt64 = 0, isCritical: Bool = false
        ) {
            self.version = version
            self.build = build
            self.notes = notes
            self.date = date
            self.byteCount = byteCount
            self.isCritical = isCritical
        }
    }

    public enum Phase: Equatable {
        case idle
        /// Looking, because the user asked.
        case checking
        /// The answer to a check the user asked for: nothing newer.
        case upToDate
        /// Found, and waiting to be told what to do with it.
        case available(Release, isDownloaded: Bool)
        case downloading(Release, received: UInt64, expected: UInt64)
        /// Unpacking and checking what was downloaded.
        case preparing(Release, progress: Double)
        /// Everything is in place but the app itself, which has to close.
        case readyToInstall(Release)
        case installing(Release)
        case failed(String)

        public var release: Release? {
            switch self {
            case .available(let release, _), .downloading(let release, _, _), .preparing(let release, _),
                 .readyToInstall(let release), .installing(let release):
                release
            case .idle, .checking, .upToDate, .failed:
                nil
            }
        }

        /// Whether this is the answer to something the user asked just now,
        /// as against an update that is there to be dealt with.
        public var isAnAnswer: Bool {
            switch self {
            case .checking, .upToDate, .failed: true
            default: false
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// Whether the sheet with the details is showing.
    public var isShowingDetails = false
    /// Whether an installation is held up by the app, which was asked to
    /// quit and is still here, so that the user has to quit it.
    public private(set) var isWaitingForQuit = false
    public private(set) var lastCheckDate: Date?

    /// The version that is running.
    public let currentVersion: String

    @ObservationIgnored private var engine: (any UpdateEngine)?
    /// Whether the user has chosen to install the update that is on its
    /// way, so that there is nothing left to ask once it is ready.
    @ObservationIgnored private var installsWhenReady = false
    /// Whether the user is in the middle of something an update should not
    /// put itself in front of: a session with another computer.
    @ObservationIgnored public var isBusy: () -> Bool = { false }

    /// Mirrors of the engine's settings, so that a switch bound to them
    /// redraws when they change.
    public private(set) var checksAutomaticallyValue = true
    public private(set) var installsAutomaticallyValue = false

    public init(currentVersion: String? = nil) {
        self.currentVersion = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: - The engine

    /// Whether this app can update itself at all.
    public var canUpdate: Bool { engine != nil }

    public func attach(_ engine: any UpdateEngine) {
        self.engine = engine
        checksAutomaticallyValue = engine.checksAutomatically
        installsAutomaticallyValue = engine.installsAutomatically
        lastCheckDate = engine.lastCheckDate
    }

    /// The engine reports where things stand.
    ///
    /// - Parameter userInitiated: Whether this follows from something the
    ///   user asked for. What the user asked about is shown at once; what
    ///   was found in the background waits beside their work until they
    ///   are not in the middle of a session.
    public func engineMoved(to phase: Phase, userInitiated: Bool) {
        let wasShowing = isShowingDetails
        self.phase = phase
        lastCheckDate = engine?.lastCheckDate ?? lastCheckDate
        if case .installing = phase {} else {
            isWaitingForQuit = false
        }
        switch phase {
        case .idle:
            installsWhenReady = false
            isShowingDetails = false
        case .checking, .upToDate, .failed:
            installsWhenReady = false
            // Only ever the answer to a question: a check in the background
            // that finds nothing, or fails, says nothing.
            isShowingDetails = userInitiated || wasShowing
        case .available:
            installsWhenReady = false
            isShowingDetails = wasShowing || userInitiated || !isBusy()
        case .readyToInstall:
            let goesOn = installsWhenReady && !isBusy()
            installsWhenReady = false
            if goesOn {
                // The user chose to install it when it was found, and
                // nothing has come up since that the app closing would
                // interrupt: it is installed without a second question.
                install()
            } else {
                // Downloaded without being asked for, or a session has
                // been opened in the meantime: closing the app is put to
                // the user.
                isShowingDetails = wasShowing || userInitiated || !isBusy()
            }
        case .installing:
            // The app is being asked to quit, and an app with a sheet up
            // does not. The notice beside the library says what is going on.
            isShowingDetails = false
        case .downloading, .preparing:
            break
        }
    }

    /// The engine asked the app to quit to finish installing, and the app
    /// is still running.
    public func engineIsWaitingForQuit() {
        guard case .installing = phase else { return }
        isWaitingForQuit = true
    }

    public func engineCheckedAt(_ date: Date?) {
        lastCheckDate = date
    }

    // MARK: - What the user does

    public var checksAutomatically: Bool {
        get { checksAutomaticallyValue }
        set {
            checksAutomaticallyValue = newValue
            engine?.checksAutomatically = newValue
        }
    }

    public var installsAutomatically: Bool {
        get { installsAutomaticallyValue }
        set {
            installsAutomaticallyValue = newValue
            engine?.installsAutomatically = newValue
        }
    }

    /// Whether asking for a check would do anything now.
    public var canCheck: Bool {
        guard engine != nil else { return false }
        switch phase {
        case .idle, .upToDate, .failed: return true
        default: return false
        }
    }

    /// Whether there is something in the sheet to come back to: an update
    /// that is waiting or on its way. Not one that is being installed, for
    /// which the app has to quit, and it will not from under a sheet.
    public var canShowDetails: Bool {
        if case .installing = phase { return false }
        return phase.release != nil
    }

    /// Opens the sheet over an update, if there is one to open it over.
    public func showDetails() {
        guard canShowDetails else { return }
        isShowingDetails = true
    }

    public func checkNow() {
        if phase.release != nil {
            // There is one already: show it.
            showDetails()
            return
        }
        guard canCheck else { return }
        if phase.isAnAnswer {
            engine?.acknowledge()
        }
        engine?.check()
    }

    /// Downloads and prepares the update and goes on to install it, or
    /// installs the one that is ready.
    public func install() {
        if case .available = phase {
            installsWhenReady = true
        }
        if case .readyToInstall = phase {
            // Installing ends with the app being asked to quit, and an app
            // with a sheet up does not quit. The sheet goes first; the
            // engine waits until it has.
            isShowingDetails = false
        }
        engine?.respond(.install)
    }

    public func later() {
        installsWhenReady = false
        isShowingDetails = false
        engine?.respond(.later)
    }

    public func skip() {
        installsWhenReady = false
        isShowingDetails = false
        engine?.respond(.skip)
    }

    public func cancel() {
        installsWhenReady = false
        engine?.cancel()
    }

    /// Closes the sheet. An answer that has been read is done with; an
    /// update that is waiting stays where it can be come back to.
    public func dismiss() {
        isShowingDetails = false
        if case .upToDate = phase {
            engine?.acknowledge()
        } else if case .failed = phase {
            engine?.acknowledge()
        }
    }
}
