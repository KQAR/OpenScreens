import CoreGraphics
import Foundation
import RFBTestServer
import Testing
@testable import OpenScreensUI

/// Where the last-seen pictures of screens are kept, and where they are not.
struct PreviewStoreTests {
    /// A folder of the test's own, removed by the caller.
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenScreensPreviews-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func aStoreWithAFolderKeepsItsPreviewsThere() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let image = try #require(DemoDesktop.testCard())

        PreviewStore(directory: directory).save(image, for: id)

        #expect(try files(in: directory) == ["\(id.uuidString).jpg"])
        // Another store on the same folder finds it, as the next launch does.
        let found = try #require(PreviewStore(directory: directory).image(for: id))
        #expect(found.width == 320)
        #expect(found.height == 200)
    }

    @Test func aStoreWithoutAFolderKeepsThemInMemory() throws {
        let store = PreviewStore(directory: nil)
        let id = UUID()
        let image = try #require(DemoDesktop.testCard())
        let revision = store.revision

        store.save(image, for: id)

        let found = try #require(store.image(for: id))
        #expect(found.width == 320)
        #expect(found.height == 200)
        // Views showing a preview reload when this moves.
        #expect(store.revision == revision + 1)
        #expect(store.image(for: UUID()) == nil)

        store.remove(for: id)
        #expect(store.image(for: id) == nil)
    }

    @Test func removingAPreviewTakesItsFile() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PreviewStore(directory: directory)
        let kept = UUID()
        let removed = UUID()
        let image = try #require(DemoDesktop.testCard())
        store.save(image, for: kept)
        store.save(image, for: removed)

        store.remove(for: removed)

        #expect(try files(in: directory) == ["\(kept.uuidString).jpg"])
        #expect(store.image(for: removed) == nil)
        #expect(store.image(for: kept) != nil)
    }

    @Test func clearingRemovesEveryPreview() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PreviewStore(directory: directory)
        let ids = [UUID(), UUID()]
        let image = try #require(DemoDesktop.testCard())
        for id in ids { store.save(image, for: id) }

        store.removeAll()

        #expect(try files(in: directory).isEmpty)
        for id in ids { #expect(store.image(for: id) == nil) }

        // A store that has no folder forgets what it holds just the same.
        let inMemory = PreviewStore(directory: nil)
        inMemory.save(image, for: ids[0])
        inMemory.removeAll()
        #expect(inMemory.image(for: ids[0]) == nil)
    }

    @Test func aLargeScreenIsKeptSmall() throws {
        let store = PreviewStore(directory: nil)
        let id = UUID()
        let image = try #require(DemoDesktop.testCard(width: 3840, height: 2400))

        store.save(image, for: id)

        let found = try #require(store.image(for: id))
        #expect(found.width == PreviewStore.maximumDimension)
        #expect(found.height == 600)
    }
}
