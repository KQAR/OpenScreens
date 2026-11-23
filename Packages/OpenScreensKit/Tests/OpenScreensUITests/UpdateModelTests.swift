import Foundation
import OpenScreensCore
import Testing
@testable import OpenScreensUI

/// Stands in for whatever finds and installs updates, and writes down what
/// it was asked.
private final class FakeEngine: UpdateEngine {
    var checksAutomatically = true
    var installsAutomatically = false
    var lastCheckDate: Date?
    var asked: [String] = []
    /// Whether the sheet was up each time an answer arrived.
    var sheetWasUp: [Bool] = []
    weak var model: UpdateModel?

    func check() { asked.append("check") }
    func respond(_ choice: UpdateChoice) {
        asked.append("respond \(choice)")
        sheetWasUp.append(model?.isShowingDetails ?? false)
    }
    func cancel() { asked.append("cancel") }
    func acknowledge() { asked.append("acknowledge") }
}

@Suite struct UpdateModelTests {
    private let release = UpdateModel.Release(
        version: "1.3.0", build: "5", notes: ReleaseNotes(markdown: "- Updates itself."),
        byteCount: 14_000_000)

    private func make(busy: Bool = false) -> (UpdateModel, FakeEngine) {
        let model = UpdateModel(currentVersion: "1.2.0")
        let engine = FakeEngine()
        engine.model = model
        model.attach(engine)
        model.isBusy = { busy }
        return (model, engine)
    }

    @Test func anAppWithNothingToUpdateWithOffersNothing() {
        let model = UpdateModel(currentVersion: "1.2.0")
        #expect(!model.canUpdate)
        #expect(!model.canCheck)
        model.checkNow()
        #expect(model.phase == .idle)
        #expect(!model.isShowingDetails)
    }

    @Test func whatTheUserAskedAboutIsShownAtOnce() {
        let (model, engine) = make(busy: true)
        model.checkNow()
        #expect(engine.asked == ["check"])
        model.engineMoved(to: .checking, userInitiated: true)
        #expect(model.isShowingDetails)
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: true)
        // Even in the middle of a session: they asked.
        #expect(model.isShowingDetails)
        #expect(model.phase.release == release)
    }

    @Test func anUpdateFoundInTheBackgroundWaitsBesideASession() {
        let (model, _) = make(busy: true)
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: false)
        // There to be seen, and not in front of the work.
        #expect(model.phase.release == release)
        #expect(!model.isShowingDetails)
    }

    @Test func anUpdateFoundInTheBackgroundIsShownWhenNothingIsGoingOn() {
        let (model, _) = make(busy: false)
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: false)
        #expect(model.isShowingDetails)
    }

    @Test func aCheckInTheBackgroundThatFindsNothingSaysNothing() {
        let (model, _) = make()
        model.engineMoved(to: .upToDate, userInitiated: false)
        #expect(!model.isShowingDetails)
        model.engineMoved(to: .failed("The feed could not be read."), userInitiated: false)
        #expect(!model.isShowingDetails)
    }

    @Test func theChoicesReachTheEngine() {
        let (model, engine) = make()
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: true)
        model.install()
        #expect(engine.asked == ["respond install"])
        // The sheet stays for the download to be watched in.
        #expect(model.isShowingDetails)

        model.engineMoved(to: .downloading(release, received: 0, expected: 14_000_000), userInitiated: true)
        #expect(model.isShowingDetails)
    }

    // One choice is the whole update: what was chosen when it was found is
    // not asked about again when it is ready.

    @Test func anUpdateTheUserChoseIsInstalledWhenItIsReady() {
        let (model, engine) = make()
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: false)
        model.install()
        model.engineMoved(to: .downloading(release, received: 0, expected: 14_000_000), userInitiated: false)
        model.engineMoved(to: .preparing(release, progress: 0.5), userInitiated: false)
        #expect(engine.asked == ["respond install"])

        model.engineMoved(to: .readyToInstall(release), userInitiated: false)
        #expect(engine.asked == ["respond install", "respond install"])
        // Up while it downloaded, and out of the way for the app to quit.
        #expect(engine.sheetWasUp == [true, false])
    }

    @Test func aSessionOpenedWhileItDownloadedIsNotClosedUnasked() {
        var busy = false
        let (model, engine) = make()
        model.isBusy = { busy }
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: false)
        model.install()
        model.engineMoved(to: .downloading(release, received: 0, expected: 14_000_000), userInitiated: false)
        busy = true
        model.engineMoved(to: .readyToInstall(release), userInitiated: false)
        // Ready, and waiting to be told.
        #expect(engine.asked == ["respond install"])
        #expect(model.phase == .readyToInstall(release))

        model.install()
        #expect(engine.asked == ["respond install", "respond install"])
    }

    @Test func anUpdateDownloadedUnaskedIsNotInstalledUnasked() {
        let (model, engine) = make()
        // Sparkle had it downloaded already; nobody has chosen anything.
        model.engineMoved(to: .readyToInstall(release), userInitiated: false)
        #expect(engine.asked.isEmpty)
        #expect(model.isShowingDetails)
        model.later()
        #expect(engine.asked == ["respond later"])
        #expect(!model.isShowingDetails)
    }

    @Test func aChoiceThatWasTakenBackIsNotActedOnLater() {
        let (model, engine) = make()
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: false)
        model.install()
        model.engineMoved(to: .downloading(release, received: 0, expected: 14_000_000), userInitiated: false)
        model.cancel()
        model.engineMoved(to: .idle, userInitiated: false)
        // Found again later, and this time already downloaded.
        model.engineMoved(to: .readyToInstall(release), userInitiated: false)
        #expect(engine.asked == ["respond install", "cancel"])
    }

    // An app with a sheet up does not quit when the system asks it to, and
    // being asked to quit is how an installation ends. Tried with the real
    // thing: with the sheet up the app stayed, the update unpacked beside it.

    @Test func theSheetIsOutOfTheWayBeforeTheAppIsAskedToQuit() {
        let (model, engine) = make()
        model.engineMoved(to: .readyToInstall(release), userInitiated: true)
        #expect(model.isShowingDetails)
        model.install()
        #expect(engine.asked == ["respond install"])
        // Closed by the time the engine hears, which goes on to quit the app.
        #expect(engine.sheetWasUp == [false])
        #expect(!model.isShowingDetails)
    }

    @Test func anInstallationUnderWayHasNoSheet() {
        let (model, _) = make()
        model.engineMoved(to: .readyToInstall(release), userInitiated: true)
        model.engineMoved(to: .installing(release), userInitiated: true)
        #expect(!model.isShowingDetails)
        // Nor one to bring back, from the notice or from the menu.
        #expect(!model.canShowDetails)
        model.showDetails()
        #expect(!model.isShowingDetails)
        model.checkNow()
        #expect(!model.isShowingDetails)
    }

    @Test func anUpdateThatIsWaitingHasASheetToComeBackTo() {
        let (model, _) = make(busy: true)
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: false)
        #expect(!model.isShowingDetails)
        #expect(model.canShowDetails)
        model.showDetails()
        #expect(model.isShowingDetails)
    }

    @Test func nothingToShowMeansNoSheet() {
        let (model, _) = make()
        #expect(!model.canShowDetails)
        model.showDetails()
        #expect(!model.isShowingDetails)
    }

    @Test func anAppThatWillNotQuitIsLeftToTheUser() {
        let (model, _) = make()
        // Only an installation waits for the app to quit.
        model.engineIsWaitingForQuit()
        #expect(!model.isWaitingForQuit)

        model.engineMoved(to: .installing(release), userInitiated: true)
        #expect(!model.isWaitingForQuit)
        model.engineIsWaitingForQuit()
        #expect(model.isWaitingForQuit)
        // Over with the installation.
        model.engineMoved(to: .idle, userInitiated: false)
        #expect(!model.isWaitingForQuit)
    }

    @Test func skippingAndLaterCloseTheSheet() {
        let (model, engine) = make()
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: true)
        model.skip()
        #expect(engine.asked == ["respond skip"])
        #expect(!model.isShowingDetails)
    }

    @Test func closingTheSheetOverAnAnswerIsHavingReadIt() {
        let (model, engine) = make()
        model.engineMoved(to: .upToDate, userInitiated: true)
        model.dismiss()
        #expect(engine.asked == ["acknowledge"])
        #expect(!model.isShowingDetails)
    }

    @Test func closingTheSheetOverAnUpdateLeavesTheUpdateWaiting() {
        let (model, engine) = make()
        model.engineMoved(to: .available(release, isDownloaded: false), userInitiated: true)
        model.dismiss()
        #expect(engine.asked.isEmpty)
        #expect(model.phase.release == release)
        // Asking again shows the one that is there instead of looking anew.
        model.checkNow()
        #expect(engine.asked.isEmpty)
        #expect(model.isShowingDetails)
    }

    @Test func aCheckCannotBeAskedForWhileOneIsGoingOn() {
        let (model, engine) = make()
        model.engineMoved(to: .checking, userInitiated: true)
        #expect(!model.canCheck)
        model.checkNow()
        #expect(engine.asked.isEmpty)
        model.engineMoved(to: .idle, userInitiated: false)
        #expect(model.canCheck)
        #expect(!model.isShowingDetails)
    }

    @Test func theSwitchesAreTheEnginesSettings() {
        let (model, engine) = make()
        #expect(model.checksAutomatically)
        #expect(!model.installsAutomatically)
        model.checksAutomatically = false
        model.installsAutomatically = true
        #expect(!engine.checksAutomatically)
        #expect(engine.installsAutomatically)
    }
}

@Suite struct UpdateWordingTests {
    private let release = UpdateModel.Release(version: "1.3.0", build: "5", byteCount: 13_576_049)

    @Test func eachStageOfAnUpdateHasItsOwnTitle() {
        #expect(UpdateWording.title(for: .available(release, isDownloaded: false), release: release)
            == "OpenScreens 1.3.0 is available")
        #expect(UpdateWording.title(for: .downloading(release, received: 1, expected: 2), release: release)
            == "Downloading OpenScreens 1.3.0")
        #expect(UpdateWording.title(for: .readyToInstall(release), release: release)
            == "OpenScreens 1.3.0 is ready to install")
    }

    @Test func anInstallationHeldUpByTheAppSaysWhatToDo() {
        let release = UpdateModel.Release(version: "1.3.0", build: "5")
        #expect(UpdateWording.detail(for: .installing(release), current: "1.2.0")
            == "The app will open again by itself.")
        #expect(UpdateWording.detail(for: .installing(release), current: "1.2.0", isWaitingForQuit: true)
            == "Quit OpenScreens to finish. It opens again by itself.")
        // Nothing else waits for the app to quit.
        #expect(UpdateWording.detail(for: .readyToInstall(release), current: "1.2.0", isWaitingForQuit: true)
            == "The app closes and opens again.")
    }

    @Test func aDownloadWhoseSizeIsNotKnownHasNoFraction() {
        #expect(UpdateWording.fraction(5, of: 0) == nil)
        #expect(UpdateWording.fraction(5, of: 10) == 0.5)
        // More arrived than was promised: full, and no further.
        #expect(UpdateWording.fraction(15, of: 10) == 1)
    }

    @Test func whatFollowsADownloadIsSaidWhileItRuns() {
        #expect(UpdateWording.whatFollows(connectedSessions: 0)
            == "When it is ready, OpenScreens closes and opens again.")
        #expect(UpdateWording.whatFollows(connectedSessions: 2)
            == "When it is ready you are asked before OpenScreens closes, because a session is open.")
    }

    @Test func whoWillBeDisconnectedIsSaidBeforeTheAppCloses() {
        #expect(!UpdateWording.relaunchWarning(connectedSessions: 0).contains("disconnected"))
        #expect(UpdateWording.relaunchWarning(connectedSessions: 1).contains("The session that is open"))
        #expect(UpdateWording.relaunchWarning(connectedSessions: 3).contains("The 3 sessions"))
    }

    @Test func theFactsLeaveOutWhatIsNotKnown() {
        let bare = UpdateModel.Release(version: "1.3.0", build: "5")
        #expect(UpdateWording.facts(about: bare, current: "1.2.0") == "You have 1.2.0")
        #expect(UpdateWording.facts(about: bare, current: "") == "")
        #expect(UpdateWording.facts(about: release, current: "1.2.0").hasPrefix("You have 1.2.0 · "))
    }

    @Test func aCheckThatWasNeverMadeIsSaidSo() {
        #expect(UpdateWording.lastChecked(nil) == "Not checked yet.")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateWording.lastChecked(now.addingTimeInterval(-10), now: now) == "Checked just now.")
    }
}

@Suite struct BundledChangeLogTests {
    /// The app shows what is new from a copy of the change log inside it.
    /// The copy is made by hand, so this is what notices when it was not.
    @Test func theCopyInTheAppIsTheChangeLogAtTheTopOfTheRepository() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let original = try String(contentsOf: root.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let copy = try String(
            contentsOf: root.appending(
                path: "Packages/OpenScreensKit/Sources/OpenScreensUI/Resources/CHANGELOG.md"),
            encoding: .utf8)
        #expect(copy == original, "run scripts/sync-changelog.sh")
    }

    @Test func theAppFindsItsChangeLog() {
        #expect(!AppModel.bundledChangeLog.entries.isEmpty)
    }
}
