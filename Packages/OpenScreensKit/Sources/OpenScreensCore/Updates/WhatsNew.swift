import Foundation

/// Decides what, if anything, to tell someone about a release when the app
/// opens after it was installed.
public enum WhatsNew {
    /// The releases to show notes for.
    ///
    /// - Parameters:
    ///   - changeLog: The change log that came with the app.
    ///   - current: The version that is running.
    ///   - lastSeen: The version whose notes were last shown, if any were.
    ///   - hasBeenUsed: Whether the app shows signs of having been used
    ///     before. Versions before 1.3 kept no record of what was seen, so
    ///     for someone coming from one of them this is all there is to tell
    ///     an update from a first launch.
    /// - Returns: Newest first. Empty when there is nothing new to this
    ///   person: a first launch, or a version already seen.
    public static func entries(
        in changeLog: ChangeLog, current: AppVersion, lastSeen: AppVersion?, hasBeenUsed: Bool
    ) -> [ChangeLog.Entry] {
        if let lastSeen {
            guard lastSeen < current else { return [] }
            return changeLog.entries(after: lastSeen, upTo: current)
        }
        // Someone opening the app for the first time has nothing to compare
        // it with, and is not kept from it by a list of changes.
        guard hasBeenUsed else { return [] }
        return changeLog.entries(after: nil, upTo: current)
    }
}
