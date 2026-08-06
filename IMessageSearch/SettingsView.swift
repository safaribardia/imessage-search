import AppKit
import Contacts
import SwiftUI

/// In-window settings page, opened by clicking the profile pane in the
/// sidebar. Read-mostly: it surfaces the current setup and offers the few
/// actions that make sense after onboarding. Styled to match onboarding:
/// soft rounded cards, capsule buttons, and a centered column.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var contacts = ContactsResolver.shared
    @State private var provider: AnswerProvider?
    @State private var isConfirmingReset = false
    // Dropping the version below the app's current one sends the root view
    // back into onboarding; see AppRootView.
    @AppStorage("onboardingVersion") private var onboardingVersion = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                profileHeader

                SettingsSection(
                    title: "Answers",
                    footer: providerFooter
                ) {
                    SettingsRow(label: "Provider") {
                        SettingsValue(providerLabel)
                    }
                }

                SettingsSection(title: "Permissions") {
                    contactsRow
                    SettingsRowDivider()
                    fullDiskAccessRow
                }

                SettingsSection(
                    title: "Search Index",
                    footer: "Search uses the fast index immediately, then switches to the higher-quality index when it is complete."
                ) {
                    SettingsRow(label: "Fast index") {
                        SettingsValue(fastIndexStatusLabel)
                    }
                    SettingsRowDivider()
                    qualityIndexRow
                    if let summary = model.indexSummary {
                        SettingsRowDivider()
                        SettingsRow(label: "Indexed") {
                            SettingsValue(
                                "\(summary.messageCount.formatted()) messages · \(summary.windowCount.formatted()) passages"
                            )
                        }
                    }
                }

                Button("Reset Onboarding") {
                    isConfirmingReset = true
                }
                .buttonStyle(.settingsCapsule)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Reset onboarding?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset Onboarding") {
                onboardingVersion = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will return to the setup walkthrough now. Nothing is deleted.")
        }
        .task {
            // Mirrors the engine's provider selection: Codex counts only when
            // the CLI, credentials, and bundled helper are all present.
            let usesGPT = await Task.detached {
                CodexAgent.locate() != nil && CodexAgent.account != nil
            }.value
            if usesGPT, let account = CodexAgent.account {
                provider = .chatGPT(
                    accountLabel: account.email ?? account.planDisplayName ?? "ChatGPT"
                )
            } else {
                provider = .ollama(modelName: AnswerModel.name)
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(contacts.meName)
                    .font(.title2.weight(.semibold))
                Text(providerLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = contacts.meThumbnail,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                Text(String(contacts.meName.prefix(1)))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
        }
    }

    private var providerLabel: String {
        switch provider {
        case .chatGPT(let accountLabel):
            accountLabel
        case .ollama(let modelName):
            "On-device · \(modelName)"
        case nil:
            "Checking…"
        }
    }

    private var providerFooter: String {
        switch provider {
        case .chatGPT:
            "Relevant message excerpts may be sent to ChatGPT to answer your questions. The search index itself never leaves this Mac."
        case .ollama, nil:
            "Search and answers run entirely on this Mac through Ollama."
        }
    }

    @ViewBuilder
    private var contactsRow: some View {
        SettingsRow(label: "Contacts") {
            switch contacts.authorizationStatus {
            case .authorized:
                SettingsValue("Connected")
            case .notDetermined:
                Button("Connect…") {
                    model.connectContacts()
                }
                .buttonStyle(.settingsCapsule)
            case .denied, .restricted:
                HStack(spacing: 10) {
                    SettingsValue("Off")
                    Button("Open System Settings…") {
                        model.openContactsSettings()
                    }
                    .buttonStyle(.settingsCapsule)
                }
            @unknown default:
                SettingsValue("Unavailable")
            }
        }
    }

    private var fullDiskAccessRow: some View {
        SettingsRow(label: "Full Disk Access") {
            HStack(spacing: 10) {
                SettingsValue(model.isIndexReady ? "Connected" : "Needed")
                Button("Open System Settings…") {
                    model.openFullDiskAccessSettings()
                }
                .buttonStyle(.settingsCapsule)
            }
        }
    }

    @ViewBuilder
    private var qualityIndexRow: some View {
        SettingsRow(label: "Higher-quality index") {
            switch model.qualityIndexState {
            case .checking:
                SettingsValue("Checking…")
            case .installing(let fraction, _):
                if let fraction {
                    Text(
                        fraction,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    SettingsValue("Downloading…")
                }
            case .building(let coverage), .paused(let coverage):
                Text(
                    coverage.fraction,
                    format: .percent.precision(.fractionLength(0))
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            case .ready:
                SettingsValue("Ready")
            case .needsModel:
                Button("Install") {
                    model.installQualityModel()
                }
                .buttonStyle(.settingsCapsule)
            case .failed:
                Button("Retry") {
                    model.retryQualityIndex()
                }
                .buttonStyle(.settingsCapsule)
            }
        }
    }

    private var fastIndexStatusLabel: String {
        if model.isIndexing {
            let percent = model.progress.formatted(
                .percent.precision(.fractionLength(0))
            )
            return "\(model.indexStatus.isEmpty ? "Indexing…" : model.indexStatus) \(percent)"
        }
        return model.isIndexReady ? "Ready" : "Waiting to index"
    }
}

/// A titled group of rows in a soft rounded card, mirroring the panels used
/// during onboarding.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                content
            }
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 18)
    }
}

private struct SettingsValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
    }
}

/// Compact capsule action matching the onboarding secondary button, sized
/// for inline rows.
private struct SettingsCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == SettingsCapsuleButtonStyle {
    static var settingsCapsule: SettingsCapsuleButtonStyle { .init() }
}
