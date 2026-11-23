import CoreGraphics
import Testing
@testable import OpenScreensCore

@Suite struct StandardDesktopTests {
    private let minimum = CGSize(width: 720, height: 600)

    @Test func aWindowLargeEnoughGetsADesktopOfItsOwnSize() {
        let size = StandardDesktop.size(fitting: CGSize(width: 1440, height: 900), minimum: minimum)
        #expect(size == CGSize(width: 1440, height: 900))
    }

    @Test func aPhoneGetsADesktopOfItsShapeThatIsWideEnoughToWorkOn() throws {
        // An iPhone held upright.
        let size = try #require(
            StandardDesktop.size(fitting: CGSize(width: 393, height: 852), minimum: minimum))
        #expect(size.width == 720)
        // The same shape as the screen, to within the rounding.
        let screen: CGFloat = 852.0 / 393.0
        let desktop = size.height / size.width
        #expect(abs(desktop - screen) < 0.01)
    }

    @Test func aPhoneOnItsSideIsHeldToTheLeastHeight() throws {
        let size = try #require(
            StandardDesktop.size(fitting: CGSize(width: 852, height: 393), minimum: minimum))
        #expect(size.height == 600)
        #expect(size.width > 852)
    }

    @Test func sidesAreEvenNumbers() throws {
        let size = try #require(
            StandardDesktop.size(fitting: CGSize(width: 1001, height: 701), minimum: minimum))
        #expect(size == CGSize(width: 1002, height: 702))
    }

    @Test func moreSpaceMakesAWiderDesktop() throws {
        let roomy = try #require(StandardDesktop.size(
            fitting: CGSize(width: 393, height: 852), minimum: CGSize(width: 1024, height: 600)))
        #expect(roomy.width == 1024)
    }

    @Test func noSideIsLongerThanAServerCanBeExpectedToMake() throws {
        let size = try #require(
            StandardDesktop.size(fitting: CGSize(width: 100, height: 4000), minimum: minimum))
        #expect(size.height <= StandardDesktop.longestSide)
        #expect(size.width >= 2)
    }

    @Test func aViewWithNoSizeGetsNoDesktop() {
        #expect(StandardDesktop.size(fitting: .zero, minimum: minimum) == nil)
        #expect(StandardDesktop.size(
            fitting: CGSize(width: CGFloat.nan, height: 600), minimum: minimum) == nil)
    }
}
