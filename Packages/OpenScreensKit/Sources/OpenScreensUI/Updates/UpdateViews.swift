import OpenScreensCore
import SwiftUI

// What the user sees of an update: a notice above the library while one is
// waiting, a sheet with what is in it and what to do about it, and after it
// has been installed, what changed.

extension View {
    /// Shows this window's share of updates: the sheet for one that is
    /// waiting, where the app can update itself, and what is new after an
    /// update everywhere. The notice that one is waiting is
    /// ``updateBanner()``, which goes on the library itself.
    public func updateNotices() -> some View {
        modifier(UpdateNotices())
    }

    /// Puts the notice that an update is waiting above this view, where the
    /// app can update itself.
    ///
    /// It belongs on what is beside the sidebar. Laid over the whole window
    /// it covers the sidebar's first rows, which do not move out of its way
    /// as the library does.
    func updateBanner() -> some View {
        modifier(UpdateBannerInset())
    }
}

private struct UpdateBannerInset: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        #if os(macOS)
        content.safeAreaInset(edge: .top, spacing: 0) {
            UpdateBanner()
                .animation(.snappy, value: model.updates.phase.release?.version)
        }
        #else
        content
        #endif
    }
}

private struct UpdateNotices: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var updates = model.updates
        content
            #if os(macOS)
            .sheet(isPresented: $updates.isShowingDetails) {
                UpdateSheet()
                    .environment(model)
            }
            #endif
            .sheet(isPresented: Binding(
                get: { !model.whatsNew.isEmpty },
                set: { if !$0 { model.dismissWhatsNew() } })
            ) {
                WhatsNewSheet(entries: model.whatsNew) {
                    model.dismissWhatsNew()
                }
            }
            .task {
                model.prepareWhatsNew()
            }
    }
}

// MARK: - What changed

/// What is new in the version that was just installed.
struct WhatsNewSheet: View {
    let entries: [ChangeLog.Entry]
    let onDone: () -> Void

    private var title: String {
        guard let newest = entries.first else { return "What's New" }
        return "What's New in OpenScreens \(newest.version)"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppIconImage(size: 72)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)
            .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if entries.count > 1 {
                            // More than one release went by since last time.
                            Text("Version \(entry.version.description)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 0 : 6)
                        }
                        ReleaseNotesView(notes: entry.notes)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }

            Divider()
            Button(action: onDone) {
                Text("Continue")
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(16)
        }
        #if os(macOS)
        .frame(width: 560, height: 600)
        #else
        .presentationDetents([.large])
        #endif
    }
}

#if os(macOS)

// MARK: - The notice

/// Says, at the top of the library, that an update is waiting or on its way,
/// for as long as it is.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        if updates.phase.release != nil {
            UpdateBannerContent()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassPanel(cornerRadius: 16, tint: .accentColor.opacity(0.12))
                .contentShape(.rect)
                .onTapGesture {
                    updates.showDetails()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        }
    }
}

/// What the notice says and offers, without the glass it sits on.
struct UpdateBannerContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        if let release = updates.phase.release {
            HStack(spacing: 12) {
                Image(systemName: symbol(for: updates.phase))
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 2) {
                    Text(UpdateWording.title(for: updates.phase, release: release))
                        .font(.callout.weight(.semibold))
                    detail(for: updates.phase)
                }

                Spacer(minLength: 12)
                actions(for: updates.phase)
            }
        }
    }

    private func symbol(for phase: UpdateModel.Phase) -> String {
        switch phase {
        case .readyToInstall: "checkmark.circle.fill"
        case .installing: "gearshape.circle.fill"
        default: "arrow.down.circle.fill"
        }
    }

    @ViewBuilder
    private func detail(for phase: UpdateModel.Phase) -> some View {
        switch phase {
        case .downloading(_, let received, let expected):
            ProgressView(value: UpdateWording.fraction(received, of: expected))
                .frame(maxWidth: 220)
        case .preparing(_, let progress):
            ProgressView(value: progress)
                .frame(maxWidth: 220)
        default:
            Text(UpdateWording.detail(
                for: phase, current: model.updates.currentVersion,
                isWaitingForQuit: model.updates.isWaitingForQuit))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(for phase: UpdateModel.Phase) -> some View {
        switch phase {
        case .available:
            Button("What's New") {
                model.updates.showDetails()
            }
            .buttonStyle(.glass)
            Button("Update") {
                model.updates.install()
            }
            .buttonStyle(.glassProminent)
        case .readyToInstall:
            Button("Install and Relaunch") {
                model.updates.showDetails()
            }
            .buttonStyle(.glassProminent)
        case .installing where model.updates.isWaitingForQuit:
            Button("Quit OpenScreens") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.glassProminent)
        case .downloading:
            Button("Cancel") {
                model.updates.cancel()
            }
            .buttonStyle(.glass)
        default:
            EmptyView()
        }
    }
}

// MARK: - The sheet

/// Everything about an update: which version, what is in it, how far along
/// it is and what can be done next. Also the answer to "Check for Updates"
/// when there is none.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model

    private var connectedSessions: Int {
        model.sessions.sessions.filter(\.isConnected).count
    }

    var body: some View {
        let updates = model.updates
        Group {
            if let release = updates.phase.release {
                VStack(spacing: 0) {
                    header(release, phase: updates.phase)
                    Divider()
                    ScrollView {
                        notes(release)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                    }
                    Divider()
                    footer(updates.phase)
                        .padding(16)
                }
                .frame(width: 560, height: 580)
            } else {
                answer(updates.phase)
                    .padding(28)
                    .frame(width: 400)
            }
        }
        // Whatever is going on is not stopped by closing the sheet with
        // Escape; an update that is waiting stays in the notice.
        .interactiveDismissDisabled(false)
    }

    private func header(_ release: UpdateModel.Release, phase: UpdateModel.Phase) -> some View {
        HStack(spacing: 16) {
            AppIconImage(size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenScreens \(release.version)")
                    .font(.title2.weight(.semibold))
                Text(UpdateWording.facts(about: release, current: model.updates.currentVersion))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if release.isCritical {
                    Label("This update fixes something important.", systemImage: "exclamationmark.shield.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func notes(_ release: UpdateModel.Release) -> some View {
        if release.notes.isEmpty {
            Text("No notes came with this version.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ReleaseNotesView(notes: release.notes)
        }
    }

    @ViewBuilder
    private func footer(_ phase: UpdateModel.Phase) -> some View {
        switch phase {
        case .available(_, let isDownloaded):
            HStack(spacing: 10) {
                Button("Skip This Version") {
                    model.updates.skip()
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Later") {
                    model.updates.later()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                Button(isDownloaded ? "Install" : "Download and Install") {
                    model.updates.install()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        case .downloading(_, let received, let expected):
            progress(
                UpdateWording.downloaded(received, of: expected),
                value: UpdateWording.fraction(received, of: expected)
            ) {
                Button("Cancel") {
                    model.updates.cancel()
                }
                .buttonStyle(.glass)
            }
        case .preparing(_, let amount):
            progress("Checking and unpacking the download…", value: amount) {
                EmptyView()
            }
        case .readyToInstall:
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to install.")
                        .font(.callout.weight(.medium))
                    Text(UpdateWording.relaunchWarning(connectedSessions: connectedSessions))
                        .font(.caption)
                        .foregroundStyle(connectedSessions > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Later") {
                    model.updates.later()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") {
                    model.updates.install()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing. OpenScreens will open again by itself.")
                    .font(.callout)
                Spacer()
            }
        case .idle, .checking, .upToDate, .failed:
            EmptyView()
        }
    }

    private func progress<Trailing: View>(
        _ label: String, value: Double?, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: value)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // What happens when this is done, said while there is
                // still time to save something.
                Text(UpdateWording.whatFollows(connectedSessions: connectedSessions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            trailing()
        }
    }

    /// The answer to a check the user asked for, when it is not an update.
    @ViewBuilder
    private func answer(_ phase: UpdateModel.Phase) -> some View {
        VStack(spacing: 14) {
            switch phase {
            case .checking:
                ProgressView()
                    .controlSize(.large)
                Text("Checking for updates…")
                    .font(.headline)
                Button("Cancel") {
                    model.updates.cancel()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("The update could not be done")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Link("Download It Yourself", destination: AppLinks.latestRelease)
                        .buttonStyle(.glass)
                    Button("OK") {
                        model.updates.dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            default:
                AppIconImage(size: 64)
                Text("You're up to date")
                    .font(.headline)
                Text("OpenScreens \(model.updates.currentVersion) is the newest version there is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("OK") {
                    model.updates.dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Settings

/// Whether and how the app keeps itself up to date.
struct UpdatesSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIconImage(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UpdateWording.status(for: updates.phase, current: updates.currentVersion))
                            .font(.body.weight(.medium))
                        Text(UpdateWording.lastChecked(updates.lastCheckDate))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updates.canShowDetails {
                        Button("Show Update…") {
                            updates.showDetails()
                        }
                        .buttonStyle(.glassProminent)
                    } else if updates.phase.release != nil {
                        // Being installed: there is nothing to do but wait.
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Check Now") {
                            updates.checkNow()
                        }
                        .disabled(!updates.canCheck)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Check for Updates Automatically", isOn: $updates.checksAutomatically)
                Toggle("Install Updates Automatically", isOn: $updates.installsAutomatically)
                    .disabled(!updates.checksAutomatically)
            } footer: {
                Text("OpenScreens looks once a day at the project's releases on GitHub, and nowhere else. An update is checked against the project's signing key before it is installed. Installed automatically, an update is put in place when you next quit.")
            }

            Section {
                Link(destination: AppLinks.releases) {
                    Label("Every Release and What Changed", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .formStyle(.grouped)
        // The sheet belongs to the library window. Asked for from here, it
        // is shown here, so that the answer is not behind this window.
        .sheet(isPresented: Binding(
            get: { updates.isShowingDetails && updates.phase.isAnAnswer },
            set: { if !$0 { updates.dismiss() } })
        ) {
            UpdateSheet()
                .environment(model)
        }
    }
}

#endif

// MARK: - Wording

/// The sentences of the update interface, in one place and without a view
/// around them, so that they can be read and tested.
enum UpdateWording {
    static func title(for phase: UpdateModel.Phase, release: UpdateModel.Release) -> String {
        switch phase {
        case .downloading: "Downloading OpenScreens \(release.version)"
        case .preparing: "Preparing OpenScreens \(release.version)"
        case .readyToInstall: "OpenScreens \(release.version) is ready to install"
        case .installing: "Installing OpenScreens \(release.version)"
        default: "OpenScreens \(release.version) is available"
        }
    }

    static func detail(
        for phase: UpdateModel.Phase, current: String, isWaitingForQuit: Bool = false
    ) -> String {
        switch phase {
        case .readyToInstall: "The app closes and opens again."
        case .installing where isWaitingForQuit:
            "Quit OpenScreens to finish. It opens again by itself."
        case .installing: "The app will open again by itself."
        default: current.isEmpty ? "A newer version than this one." : "You have \(current)."
        }
    }

    /// The line under an update's name: what is running, how large the
    /// download is and when it came out, as far as each is known.
    static func facts(about release: UpdateModel.Release, current: String) -> String {
        var facts: [String] = []
        if !current.isEmpty {
            facts.append("You have \(current)")
        }
        if release.byteCount > 0 {
            facts.append(size(release.byteCount))
        }
        if let date = release.date {
            facts.append(date.formatted(date: .long, time: .omitted))
        }
        return facts.joined(separator: " · ")
    }

    static func size(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file))
    }

    /// How much of a download has arrived, as a fraction. `nil` while the
    /// size is not known, which a progress bar shows as going on.
    static func fraction(_ received: UInt64, of expected: UInt64) -> Double? {
        guard expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    static func downloaded(_ received: UInt64, of expected: UInt64) -> String {
        guard expected > 0 else { return "Downloading… \(size(received))" }
        return "Downloading… \(size(min(received, expected))) of \(size(expected))"
    }

    /// What happens once an update the user chose has been downloaded and
    /// checked.
    static func whatFollows(connectedSessions: Int) -> String {
        connectedSessions == 0
            ? "When it is ready, OpenScreens closes and opens again."
            : "When it is ready you are asked before OpenScreens closes, because a session is open."
    }

    static func relaunchWarning(connectedSessions: Int) -> String {
        switch connectedSessions {
        case 0: "OpenScreens closes and opens again."
        case 1: "OpenScreens closes and opens again. The session that is open will be disconnected."
        default: "OpenScreens closes and opens again. The \(connectedSessions) sessions that are open will be disconnected."
        }
    }

    static func status(for phase: UpdateModel.Phase, current: String) -> String {
        if let release = phase.release {
            return title(for: phase, release: release)
        }
        switch phase {
        case .checking: return "Checking for updates…"
        case .failed: return "The last check did not go through"
        default: return current.isEmpty ? "OpenScreens" : "OpenScreens \(current)"
        }
    }

    static func lastChecked(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Not checked yet." }
        if now.timeIntervalSince(date) < 90 {
            return "Checked just now."
        }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }
}
