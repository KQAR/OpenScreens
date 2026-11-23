#if os(macOS)
import AppKit
import OpenScreensCore
import Sparkle

/// Keeps the Mac app up to date with Sparkle.
///
/// Sparkle does what must not be got wrong: it reads the feed of releases,
/// downloads one, checks it against the project's signing key and against
/// the signature of the app it is replacing, puts it in place and opens the
/// app again. None of what the user sees is Sparkle's. Where an update
/// stands is handed to the app's ``UpdateModel``, and the notice, the sheet
/// and the settings are drawn from that.
///
/// Sparkle asks its questions by handing over something to call with the
/// answer. Those are kept here until the user has chosen.
final class SparkleUpdater: NSObject, UpdateEngine {
    private let model: UpdateModel
    private var updater: SPUUpdater?

    /// What Sparkle is waiting to be told: whether to install.
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    /// Stops the check or the download under way.
    private var cancellation: (() -> Void)?
    /// Tells Sparkle the user has read what it had to say.
    private var acknowledgement: (() -> Void)?

    private var release: UpdateModel.Release?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    /// Whether the update cycle under way began with the user asking.
    private var userInitiated = false
    /// Whether the user asked for a look while Sparkle was in the middle of
    /// something of its own, and is being kept waiting for it.
    private var isWaitingToCheck = false

    /// Where to read releases from in place of the feed the app was built
    /// with, for trying an update out. Whatever a feed offers still has to
    /// be signed with the project's key, and so does the feed, so this
    /// lets nobody install anything that is not a release of OpenScreens.
    private static let feedOverride = ProcessInfo.processInfo.environment["OPENSCREENS_UPDATE_FEED"]
    /// With a feed override: look for an update at once and answer what is
    /// asked about it the way someone who wants it would, so that a script
    /// can watch one happen from the first look to the app opening again.
    private static let installsUnasked =
        feedOverride != nil && ProcessInfo.processInfo.environment["OPENSCREENS_UPDATE_UNASKED"] == "1"

    /// - Parameter isIsolated: Whether this run keeps its data to itself,
    ///   as tests and demonstrations do. Those are not updated.
    init(model: UpdateModel, isIsolated: Bool) {
        self.model = model
        super.init()

        // Trying an update out is the one reason to update such a run.
        guard !isIsolated || Self.feedOverride != nil else { return }
        #if DEBUG
        // A build out of Xcode is not something to replace with a release.
        guard Self.feedOverride != nil else { return }
        #endif

        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            // Without a feed or a key in its Info.plist the app cannot be
            // updated, and then it offers nothing to do with updates.
            NSLog("OpenScreens cannot update itself: %@", error.localizedDescription)
            return
        }
        self.updater = updater
        model.attach(self)
        if Self.installsUnasked {
            lookUnasked(updater, triesLeft: 120)
        }
    }

    /// Watched by a script, which is not going to wait a day for the first
    /// look. As it starts, Sparkle finds out whether an earlier run left an
    /// installation half done, and on a first launch goes on to look at the
    /// feed by itself; until it is through it takes no request.
    private func lookUnasked(_ updater: SPUUpdater, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, triesLeft > 0, self.release == nil else { return }
            if updater.sessionInProgress {
                self.lookUnasked(updater, triesLeft: triesLeft - 1)
            } else {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    // MARK: - UpdateEngine

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    func check() {
        guard let updater else { return }
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
            return
        }
        // Sparkle is in the middle of something it began by itself: a look
        // at the feed, or a download nobody had to be asked about. Until
        // that is over it takes no request, and would let this one drop
        // without a word. So the user is shown that the app is looking, and
        // Sparkle is asked as soon as it can be.
        guard !isWaitingToCheck else { return }
        isWaitingToCheck = true
        userInitiated = true
        move(to: .checking)
        checkWhenFree(updater)
    }

    private func checkWhenFree(_ updater: SPUUpdater) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isWaitingToCheck else { return }
            if updater.canCheckForUpdates {
                self.isWaitingToCheck = false
                // Either shows what Sparkle found in the meantime, or looks.
                updater.checkForUpdates()
            } else {
                self.checkWhenFree(updater)
            }
        }
    }

    func respond(_ choice: UpdateChoice) {
        guard let reply = self.choice else { return }
        self.choice = nil
        switch choice {
        case .install:
            if case .readyToInstall = model.phase {
                // What Sparkle does with this answer is ask the app to quit.
                whenNoSheetIsUp { reply(.install) }
            } else {
                reply(.install)
            }
        case .later: reply(.dismiss)
        case .skip: reply(.skip)
        }
    }

    // MARK: - Quitting to install

    // AppKit does not quit an app that has a sheet up: asked to, as Sparkle
    // asks through the system, it stays as it is and says nothing. Tried
    // with the update's own sheet up, the app sat there with the update
    // unpacked, and installed it only when it was quit by hand. So no
    // sheet may be up by the time Sparkle asks.

    private static var windowsWithSheets: [NSWindow] {
        NSApp.windows.filter { $0.attachedSheet != nil }
    }

    private static func endSheets() {
        for window in windowsWithSheets {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
    }

    /// Runs `body` once no window has a sheet up.
    ///
    /// The update's own sheet was closed when the user chose, and is on its
    /// way out. Any other, in whatever window, is closed here after a
    /// moment: the user has said the app may close.
    private func whenNoSheetIsUp(waited: TimeInterval = 0, _ body: @escaping () -> Void) {
        guard !Self.windowsWithSheets.isEmpty, waited < 3 else {
            body()
            return
        }
        if waited >= 1 {
            Self.endSheets()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.whenNoSheetIsUp(waited: waited + 0.1, body)
        }
    }

    /// The app was asked to quit and this is still running: asks again,
    /// with whatever sheet has come up since out of the way, and in the end
    /// leaves the quitting to the user. Sparkle installs whenever the app
    /// goes.
    private func insistOnQuitting(_ askAgain: @escaping () -> Void, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, case .installing = self.model.phase else { return }
            guard triesLeft > 0 else {
                self.model.engineIsWaitingForQuit()
                return
            }
            Self.endSheets()
            askAgain()
            self.insistOnQuitting(askAgain, triesLeft: triesLeft - 1)
        }
    }

    func cancel() {
        if isWaitingToCheck {
            // Nothing of the user's has begun yet.
            isWaitingToCheck = false
            userInitiated = false
            move(to: .idle)
            return
        }
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    func acknowledge() {
        let acknowledgement = self.acknowledgement
        self.acknowledgement = nil
        acknowledgement?()
        if model.phase.isAnAnswer {
            model.engineMoved(to: .idle, userInitiated: false)
        }
    }

    // MARK: - From Sparkle to the model

    private func move(to phase: UpdateModel.Phase) {
        model.engineMoved(to: phase, userInitiated: userInitiated)
    }

    /// Watched by a script: chooses to install, by the way the button in
    /// the sheet does, and says whether the sheet was up at the time. That
    /// matters, because the next thing Sparkle does is ask the app to quit.
    private func installUnaskedIfWatched() {
        guard Self.installsUnasked else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            // Nothing to choose where the app went on by itself.
            guard let self, self.choice != nil else { return }
            let sheetIsUp = NSApp.windows.contains { $0.attachedSheet != nil }
            NSLog("OpenScreens update trial: choosing to install; the sheet is %@", sheetIsUp ? "up" : "not up")
            self.model.install()
        }
    }

    /// A release in the feed, as the interface shows one.
    private static func release(from item: SUAppcastItem) -> UpdateModel.Release {
        var notes = ReleaseNotes(blocks: [])
        if let text = item.itemDescription, !text.isEmpty {
            if item.itemDescriptionFormat == "html" {
                // The project's own feed is written in Markdown. Notes from
                // anywhere else are shown as the text that is in them.
                let plain = (try? NSAttributedString(
                    data: Data(text.utf8),
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil))?.string
                notes = ReleaseNotes(markdown: plain ?? text)
            } else {
                notes = ReleaseNotes(markdown: text)
            }
        }
        return UpdateModel.Release(
            version: item.displayVersionString, build: item.versionString, notes: notes,
            date: item.date, byteCount: item.contentLength, isCritical: item.isCriticalUpdate)
    }
}

// MARK: - What Sparkle asks to have shown

extension SparkleUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The app says in its Info.plist that it checks by itself, and in
        // its settings how to stop it, so this is not put to the user.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        self.cancellation = cancellation
        move(to: .checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        userInitiated = state.userInitiated
        cancellation = nil
        let release = Self.release(from: appcastItem)
        self.release = release
        choice = reply

        switch state.stage {
        case .notDownloaded:
            move(to: .available(release, isDownloaded: false))
        case .downloaded:
            move(to: .available(release, isDownloaded: true))
        case .installing:
            // Already in place but for the app itself, which has to close.
            move(to: .readyToInstall(release))
        @unknown default:
            move(to: .available(release, isDownloaded: false))
        }
        installUnaskedIfWatched()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The feed carries its notes in it; there is nothing to fetch.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        self.acknowledgement = acknowledgement
        move(to: .upToDate)
        if !userInitiated || Self.installsUnasked {
            // Nobody asked, so nobody is waiting for the answer.
            acknowledge()
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        choice = nil
        self.acknowledgement = acknowledgement
        move(to: .failed(error.localizedDescription))
        if !userInitiated || Self.installsUnasked {
            acknowledge()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        if let release {
            move(to: .downloading(release, received: 0, expected: release.byteCount))
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        if let release {
            move(to: .downloading(release, received: receivedLength, expected: expectedLength))
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        if let release {
            // A server that understated the size is not shown as over full.
            let expected = max(expectedLength, receivedLength)
            move(to: .downloading(release, received: receivedLength, expected: expected))
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        if let release {
            move(to: .preparing(release, progress: 0))
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if let release {
            move(to: .preparing(release, progress: progress))
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        if let release {
            move(to: .readyToInstall(release))
        }
        installUnaskedIfWatched()
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        if let release {
            move(to: .installing(release))
        }
        if !applicationTerminated {
            insistOnQuitting(retryTerminatingApplication, triesLeft: 3)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // The app that opens again says what is new; this one has nothing
        // to add.
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        release = nil
        // The user is waiting for a look of their own, which comes next.
        guard !isWaitingToCheck else { return }
        // An answer the user has not read yet stays until they have.
        if acknowledgement == nil {
            move(to: .idle)
        }
        userInitiated = false
    }

    func showUpdateInFocus() {
        model.isShowingDetails = true
        NSApp.activate()
    }
}

// MARK: - What Sparkle asks about how to proceed

extension SparkleUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
    ) {
        model.engineCheckedAt(updater.lastUpdateCheckDate)
    }
}
#endif
