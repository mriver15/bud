import Foundation
import SwiftUI

/// The self-updater, as a Settings → About section.
///
/// Every `UpdateModel.Phase` gets its own rendering. The alternative is a pane
/// that quietly falls back to whatever it last knew, and a download that has
/// finished looks exactly like one that never started — so each state says what
/// it is and offers the one action that moves it along.
struct UpdateSettingsSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.lg) {
            releaseSection
            preferenceSection
        }
    }

    // MARK: - Release

    private var releaseSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Updates",
                subtitle: "Releases are signed, and checked against the key compiled into this build.",
                systemImage: "arrow.down.circle"
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    versionRow
                    if UpdateTrust.isConfigured {
                        phaseContent
                    } else {
                        unconfiguredNote
                    }
                    if model.update.installedBundle == nil {
                        bundleNote
                    }
                }
            }
        }
    }

    private var versionRow: some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Text("Installed")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 104, alignment: .leading)
            if let current = model.update.currentVersion {
                Text(current.display)
                    .font(Bud.Font.callout)
                    .textSelection(.enabled)
            } else {
                // Worth stating rather than leaving blank: an updater that cannot
                // read its own version cannot tell "newer" from "the same", so
                // every check would be a guess.
                Text("Unknown — this bundle carries no readable version.")
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.update.phase {
        case .idle:
            idleRow
        case .checking:
            checkingRow
        case .upToDate(let version):
            upToDateRow(version)
        case .available(let manifest):
            availableBlock(manifest)
        case .downloading(let fraction):
            downloadingBlock(fraction)
        case .installing:
            installingBlock
        case .installed(let version):
            installedBlock(version)
        case .failed(let message):
            failedBlock(message)
        }
    }

    private var idleRow: some View {
        HStack(spacing: Bud.Space.sm) {
            checkButton
            if let lastChecked = model.update.lastChecked {
                Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Disabled rather than replaced while a check runs, so the row does not
    /// reflow the moment the answer arrives.
    private var checkButton: some View {
        Button("Check for Updates") {
            Task { await model.update.check(feed: model.config.updateFeed) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Bud.Palette.accent)
        .disabled(model.update.phase.isBusy)
    }

    private var checkingRow: some View {
        HStack(spacing: Bud.Space.sm) {
            checkButton
            ProgressView()
                .controlSize(.small)
            Text("Checking…")
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// Quiet on purpose. Being current is the ordinary outcome, and a badge for
    /// the expected result turns every check into an event.
    private func upToDateRow(_ version: BudVersion) -> some View {
        HStack(spacing: Bud.Space.sm) {
            Text("Up to date. The newest release is \(version.display).")
                .font(Bud.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Check Again") {
                Task { await model.update.check(feed: model.config.updateFeed) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func availableBlock(_ manifest: UpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Bud.Space.sm) {
                Text("Bud \(manifest.version) · build \(manifest.build)")
                    .font(Bud.Font.body)
                if let published = Self.publishedLabel(manifest.published) {
                    Text("published \(published)")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            // The release notes are authored markdown and are shown as such.
            MarkdownView(manifest.notes)
            HStack(spacing: Bud.Space.sm) {
                Button("Install Update") {
                    Task { await model.update.install() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Bud.Palette.accent)
                .disabled(!model.update.canInstall)
                Text(Self.sizeLabel(manifest.size))
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    /// Determinate: the fraction is real, so a spinner here would discard the
    /// only thing the download actually knows.
    private func downloadingBlock(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            HStack(spacing: Bud.Space.sm) {
                Text("Downloading the update…")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var installingBlock: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            HStack(spacing: Bud.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(Bud.Font.callout)
                Spacer(minLength: 0)
            }
            Text("The new build is being written over this one. Bud has to restart before it is the copy that is running.")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func installedBlock(_ version: BudVersion) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            Button("Restart Bud") {
                model.update.relaunch()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Bud.Palette.accent)
            Text("\(version.display) is on disk and takes effect on the next start. This session is still the old build.")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failedBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Bud.Font.caption)
                .foregroundStyle(Bud.Palette.danger)
            Text(message)
                .font(Bud.Font.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") {
                model.update.dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Without a compiled-in key nothing can be verified, so there is no button
    /// to offer: it could only ever refuse.
    private var unconfiguredNote: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            Text("This build has no update signing key, so it cannot check for updates.")
                .font(Bud.Font.callout)
                .foregroundStyle(.secondary)
            Text("Bud will not install a release it cannot verify.")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A binary run straight out of `.build` has no bundle to replace, so an
    /// install would appear to succeed and change nothing.
    private var bundleNote: some View {
        Text("Bud is not running from an app bundle, so it cannot replace itself. Checking still works; installing is unavailable.")
            .font(Bud.Font.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Preferences

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Update preferences",
                subtitle: "What Bud looks for on its own.",
                systemImage: "gearshape"
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    Toggle("Check for updates automatically", isOn: autoCheckBinding)
                        .toggleStyle(.switch)
                    HStack(spacing: Bud.Space.sm) {
                        Text("Release channel")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                        Picker("Release channel", selection: channelBinding) {
                            Text("Stable").tag("stable")
                            Text("Prerelease").tag("prerelease")
                        }
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    Text("Checking is silent. Nothing is downloaded unless you press Install Update.")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { model.config.autoCheckUpdates },
            set: { newValue in
                guard newValue != model.config.autoCheckUpdates else { return }
                model.config.autoCheckUpdates = newValue
                model.persistConfig()
            }
        )
    }

    /// The channel is read when a check starts, so changing it leaves the release
    /// already on screen alone rather than blanking it mid-decision.
    private var channelBinding: Binding<String> {
        Binding(
            get: { model.config.updateChannel },
            set: { newValue in
                guard newValue != model.config.updateChannel else { return }
                model.config.updateChannel = newValue
                model.persistConfig()
            }
        )
    }

    // MARK: - Formatting

    /// The feed stamps releases in RFC3339, which is exact and unreadable. The
    /// only question a person has about a release date is roughly how old it is.
    private static func publishedLabel(_ raw: String?) -> String? {
        guard let raw, let date = try? Date(raw, strategy: .iso8601) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// One decimal, because the digit that matters is the leading one — whether
    /// this is a small download or a large one.
    private static func sizeLabel(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
