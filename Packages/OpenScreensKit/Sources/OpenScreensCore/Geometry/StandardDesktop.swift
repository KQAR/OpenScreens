import CoreGraphics

/// The desktop to ask a VNC server for, so that it fits where it is shown.
///
/// A Mac makes a display for the client at two pixels to a point. Other
/// systems are not, as a rule, set up to draw at twice the size, so their
/// desktop is asked for at one pixel to a point: what is on it then comes
/// out the size it would on a display of their own.
public enum StandardDesktop {
    /// The longest side a desktop is asked to have.
    public static let longestSide: CGFloat = 8192

    /// - Parameters:
    ///   - room: The size of the view the desktop is shown in, in points.
    ///   - minimum: The smallest desktop worth working on. A view smaller
    ///     than this gets a desktop of its own shape that is at least this
    ///     large, shown smaller.
    /// - Returns: The size in pixels, or `nil` for a view with no size.
    public static func size(fitting room: CGSize, minimum: CGSize) -> CGSize? {
        guard room.width.isFinite, room.height.isFinite, room.width >= 1, room.height >= 1 else {
            return nil
        }
        var scale = max(1, minimum.width / room.width, minimum.height / room.height)
        scale = min(scale, longestSide / room.width, longestSide / room.height)
        // Even numbers: there are servers that take no others.
        func even(_ length: CGFloat) -> CGFloat {
            max(2, (length * scale / 2).rounded() * 2)
        }
        return CGSize(width: even(room.width), height: even(room.height))
    }
}
