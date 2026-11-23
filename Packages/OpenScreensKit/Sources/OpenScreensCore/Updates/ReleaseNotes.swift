import Foundation

/// What changed in a release, as it is written in the change log and in an
/// update's feed, taken apart far enough to be laid out.
///
/// The notes are Markdown of the plainest kind: paragraphs, lists and
/// headings, with emphasis, code and links inside them. That is all the
/// change log uses, and what is not one of those is kept as a paragraph.
public struct ReleaseNotes: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case paragraph(String)
        /// One item of a list. The text may still hold emphasis and links.
        case bullet(String)
    }

    public var blocks: [Block]

    public var isEmpty: Bool { blocks.isEmpty }

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// Reads notes written in Markdown.
    public init(markdown: String) {
        var blocks: [Block] = []
        /// The lines of the paragraph or list item being put together.
        var pending: [String] = []
        var pendingIsBullet = false

        func flush() {
            guard !pending.isEmpty else { return }
            let text = pending.joined(separator: " ")
            blocks.append(pendingIsBullet ? .bullet(text) : .paragraph(text))
            pending = []
            pendingIsBullet = false
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") {
                flush()
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    blocks.append(.heading(title))
                }
            } else if let item = Self.listItem(trimmed) {
                flush()
                pending = [item]
                pendingIsBullet = true
            } else {
                // A line that goes on from the one before, as a wrapped
                // paragraph or list item does.
                pending.append(trimmed)
            }
        }
        flush()
        self.blocks = blocks
    }

    private static func listItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// The change log that comes with the app: every release and what was
/// written about it.
public struct ChangeLog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var version: AppVersion
        /// The Markdown under the release's heading.
        public var markdown: String

        public var notes: ReleaseNotes { ReleaseNotes(markdown: markdown) }
    }

    /// Newest first, as the file has them.
    public var entries: [Entry]

    /// Reads a change log in which each release is a second-level heading
    /// with its version for a title: `## 1.2.0`.
    public init(markdown: String) {
        var entries: [Entry] = []
        var version: AppVersion?
        var lines: [Substring] = []

        func close() {
            if let version {
                let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(Entry(version: version, markdown: body))
            }
            lines = []
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                close()
                // The version is the first word: a date or a name may follow.
                version = line.dropFirst(3).split(separator: " ").first.flatMap { AppVersion(String($0)) }
            } else if version != nil {
                lines.append(line)
            }
        }
        close()
        self.entries = entries
    }

    public func entry(for version: AppVersion) -> Entry? {
        entries.first { $0.version == version }
    }

    /// What someone who last ran `previous` has not seen yet: the releases
    /// after it up to and including `current`, newest first.
    public func entries(after previous: AppVersion?, upTo current: AppVersion) -> [Entry] {
        entries.filter { entry in
            entry.version <= current && previous.map { entry.version > $0 } ?? (entry.version == current)
        }
    }
}
