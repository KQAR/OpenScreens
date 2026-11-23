import OpenScreensCore
import SwiftUI

/// Release notes laid out: paragraphs, headings and lists, with the
/// emphasis, code and links inside them kept.
struct ReleaseNotesView: View {
    let notes: ReleaseNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(notes.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(Self.inline(text))
                        .font(.headline)
                        .padding(.top, 6)
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(Self.inline(text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Emphasis, code and links, as Markdown writes them. Text that is not
    /// Markdown at all comes out as it is.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The app's own icon, as the system draws it now.
struct AppIconImage: View {
    var size: CGFloat = 64

    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #else
        Group {
            if let icon = UIImage(named: "AppIcon60x60") {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            } else {
                Image(systemName: "macbook.and.iphone")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        #endif
    }
}
