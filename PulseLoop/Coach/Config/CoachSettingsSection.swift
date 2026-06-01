import SwiftUI

/// "AI Coach" block for `SettingsView`: provider mode, model, OpenAI key
/// (stored in Keychain), and the web-search toggle. Visuals reuse the existing
/// design system (`SectionHeader`, `StatusCopy`, `PulseColors`).
struct CoachSettingsSection: View {
    @State private var store = CoachSettingsStore.shared
    private let keyStore = OpenAIKeychainStore()

    @State private var keyDraft: String = ""
    @State private var hasSavedKey: Bool = false
    @State private var showKey: Bool = false
    @State private var keyError: String?

    private var flags: CoachFeatureFlags {
        CoachFeatureFlags(settings: store.settings, hasAPIKey: hasSavedKey)
    }

    var body: some View {
        SectionHeader(title: "AI Coach", action: nil)
        StatusCopy(title: "Status", body: flags.statusLine)

        labeledRow("Provider") {
            Picker("Provider", selection: providerBinding) {
                ForEach(CoachProviderMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .tint(PulseColors.accent)
        }

        labeledRow("Model") {
            Picker("Model", selection: modelBinding) {
                ForEach(CoachModel.allCases) { model in
                    Text(model.label).tag(model.rawValue)
                }
            }
            .pickerStyle(.menu)
            .tint(PulseColors.accent)
        }

        if store.settings.providerMode == .userOpenAIKey {
            keyField
        }

        toggleRow("Web search", isOn: webSearchBinding)
    }

    // MARK: - Key field

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $keyDraft)
                    } else {
                        SecureField("sk-…", text: $keyDraft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14).monospaced())
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(PulseColors.cardSoft, in: Capsule())
                .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))

                Button { showKey.toggle() } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(PulseColors.textMuted)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                QuickActionButton(label: hasSavedKey ? "Update key" : "Save key", accent: true) { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedKey {
                    QuickActionButton(label: "Remove") { removeKey() }
                }
            }

            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(PulseColors.danger)
            } else {
                Text("Stored only in your device Keychain. Used to call OpenAI directly.")
                    .font(.caption).foregroundStyle(PulseColors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        .onAppear(perform: refreshKeyState)
    }

    // MARK: - Small layout helpers

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
        }
        .tint(PulseColors.accent)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Bindings

    private var providerBinding: Binding<CoachProviderMode> {
        Binding(get: { store.settings.providerMode }, set: { store.settings.providerMode = $0 })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { store.settings.model }, set: { store.settings.model = $0 })
    }
    private var webSearchBinding: Binding<Bool> {
        Binding(get: { store.settings.enableWebSearch }, set: { store.settings.enableWebSearch = $0 })
    }

    // MARK: - Key actions

    private func refreshKeyState() {
        hasSavedKey = ((try? keyStore.readKey()) ?? nil) != nil
    }

    private func saveKey() {
        keyError = nil
        do {
            try keyStore.saveKey(keyDraft)
            keyDraft = ""
            showKey = false
            refreshKeyState()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        keyError = nil
        do {
            try keyStore.deleteKey()
            keyDraft = ""
            refreshKeyState()
        } catch {
            keyError = error.localizedDescription
        }
    }
}
