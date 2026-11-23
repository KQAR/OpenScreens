import Foundation
import Testing
@testable import OpenScreensCore

@Suite struct AppVersionTests {
    @Test func versionsAreComparedANumberAtATime() throws {
        let nine = try #require(AppVersion("1.9"))
        let ten = try #require(AppVersion("1.10"))
        let tenOne = try #require(AppVersion("1.10.1"))
        let two = try #require(AppVersion("2"))
        #expect(nine < ten)
        #expect(ten < tenOne)
        #expect(tenOne < two)
        let sorted = [two, nine, tenOne, ten].sorted()
        #expect(sorted == [nine, ten, tenOne, two])
    }

    @Test func zerosAtTheEndChangeNothing() throws {
        let short = try #require(AppVersion("1.2"))
        let long = try #require(AppVersion("1.2.0"))
        #expect(short == long)
        #expect(!(short < long))
        #expect(!(long < short))
        #expect(Set([short, long]).count == 1)
        #expect(AppVersion("1.0.0") == AppVersion("1"))
        #expect(AppVersion("0") != AppVersion("1"))
    }

    @Test(arguments: ["", "1.", ".1", "1..2", "1.2b", "v1.2", "one", "1.-2", "١.٢"])
    func whatIsNotAVersionIsNotRead(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func aVersionIsWrittenAsItWasGiven() throws {
        let padded = try #require(AppVersion(" 1.2.0 "))
        #expect(padded.description == "1.2.0")
        let ten = try #require(AppVersion("1.10"))
        #expect(ten.description == "1.10")
    }
}

@Suite struct ReleaseNotesTests {
    @Test func paragraphsListsAndHeadingsAreToldApart() {
        let notes = ReleaseNotes(markdown: """
        A release for computers that are not Macs.

        ### New

        - **Raspberry Pi OS as it comes.** Its VNC server asks for your
          user name and password.
        - A second thing.
        * And a third, with another marker.

        The end.
        """)
        #expect(notes.blocks == [
            .paragraph("A release for computers that are not Macs."),
            .heading("New"),
            .bullet("**Raspberry Pi OS as it comes.** Its VNC server asks for your user name and password."),
            .bullet("A second thing."),
            .bullet("And a third, with another marker."),
            .paragraph("The end."),
        ])
    }

    @Test func aParagraphBrokenOverLinesIsOneParagraph() {
        let notes = ReleaseNotes(markdown: "Behind this is a lab of real servers.\nIt runs three of them,\nfor real.")
        #expect(notes.blocks == [.paragraph("Behind this is a lab of real servers. It runs three of them, for real.")])
    }

    @Test func nothingWrittenIsNothingToShow() {
        #expect(ReleaseNotes(markdown: "").isEmpty)
        #expect(ReleaseNotes(markdown: "\n\n   \n").isEmpty)
        #expect(ReleaseNotes(markdown: "###").isEmpty)
    }

    @Test func linesFromAnotherSystemAreReadTheSame() {
        let notes = ReleaseNotes(markdown: "- One\r\n- Two\r\n")
        #expect(notes.blocks == [.bullet("One"), .bullet("Two")])
    }
}

@Suite struct ChangeLogTests {
    private let log = ChangeLog(markdown: """
    # Changelog

    Notable changes to OpenScreens.

    ## 1.2.0

    A release for computers that are not Macs.

    - Raspberry Pi.

    ## 1.1.1

    - A freeze was fixed.

    ## 1.1.0 (2026-11-11)

    - Faster.

    ## 1.0.0

    The first.
    """)

    @Test func everyReleaseIsFoundWithWhatWasWrittenUnderIt() throws {
        #expect(log.entries.map(\.version.description) == ["1.2.0", "1.1.1", "1.1.0", "1.0.0"])
        let version = try #require(AppVersion("1.2"))
        let entry = try #require(log.entry(for: version))
        #expect(entry.markdown == "A release for computers that are not Macs.\n\n- Raspberry Pi.")
        #expect(entry.notes.blocks == [
            .paragraph("A release for computers that are not Macs."),
            .bullet("Raspberry Pi."),
        ])
        // What comes before the first release is not a release.
        #expect(!log.entries.contains { $0.markdown.contains("Notable changes") })
    }

    @Test func someoneComingFromAnOlderVersionIsShownEverythingSince() throws {
        let current = try #require(AppVersion("1.2.0"))
        let since = log.entries(after: AppVersion("1.1.0"), upTo: current)
        #expect(since.map(\.version.description) == ["1.2.0", "1.1.1"])
        // Nothing on record of an earlier version: only this release.
        #expect(log.entries(after: nil, upTo: current).map(\.version.description) == ["1.2.0"])
        // Running what was last seen: nothing new.
        #expect(log.entries(after: current, upTo: current).isEmpty)
        // A change log that is ahead of the app says nothing of what is not out.
        let older = try #require(AppVersion("1.1.1"))
        #expect(log.entries(after: AppVersion("1.0.0"), upTo: older).map(\.version.description) == ["1.1.1", "1.1.0"])
    }

    @Test func theProjectsOwnChangeLogIsRead() throws {
        // The file at the top of the repository, which is what ships.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let text = try String(contentsOf: url.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let real = ChangeLog(markdown: text)
        #expect(real.entries.count >= 4)
        #expect(real.entries.map(\.version) == real.entries.map(\.version).sorted(by: >))
        for entry in real.entries {
            #expect(!entry.notes.isEmpty, "\(entry.version)")
        }
    }
}

@Suite struct WhatsNewTests {
    private let log = ChangeLog(markdown: """
    ## 1.3.0

    - Updates itself.

    ## 1.2.0

    - Raspberry Pi.

    ## 1.1.1

    - A freeze was fixed.
    """)

    private func shown(lastSeen: String?, hasBeenUsed: Bool, current: String = "1.3.0") throws -> [String] {
        let version = try #require(AppVersion(current))
        return WhatsNew.entries(
            in: log, current: version, lastSeen: lastSeen.flatMap(AppVersion.init), hasBeenUsed: hasBeenUsed
        ).map(\.version.description)
    }

    @Test func aFirstLaunchIsNotMetWithAListOfChanges() throws {
        #expect(try shown(lastSeen: nil, hasBeenUsed: false).isEmpty)
    }

    @Test func someoneComingFromAVersionThatKeptNoRecordIsShownThisRelease() throws {
        #expect(try shown(lastSeen: nil, hasBeenUsed: true) == ["1.3.0"])
    }

    @Test func someoneWhoSkippedAReleaseIsShownBoth() throws {
        #expect(try shown(lastSeen: "1.1.1", hasBeenUsed: true) == ["1.3.0", "1.2.0"])
    }

    @Test func whatWasSeenIsNotShownAgain() throws {
        #expect(try shown(lastSeen: "1.3.0", hasBeenUsed: true).isEmpty)
        #expect(try shown(lastSeen: "1.3", hasBeenUsed: true).isEmpty)
    }

    @Test func goingBackToAnOlderVersionShowsNothing() throws {
        #expect(try shown(lastSeen: "1.3.0", hasBeenUsed: true, current: "1.2.0").isEmpty)
    }
}
