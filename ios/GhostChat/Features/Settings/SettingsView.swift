import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var localization: LocalizationManager
    @EnvironmentObject var contacts: ContactManager
    @Environment(\.dismiss) private var dismiss

    @State private var showWipeConfirm = false
    @State private var showDashboard = false

    var body: some View {
        NavigationStack {
            Form {
                privacySection
                securitySection
                timersSection
                languageSection
                dangerSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(localization.localized("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localization.localized("action.done")) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showDashboard) {
                SecurityDashboardView()
            }
            .alert(localization.localized("settings.wipe"), isPresented: $showWipeConfirm) {
                Button(localization.localized("action.cancel"), role: .cancel) {}
                Button(localization.localized("settings.wipe"), role: .destructive) {
                    try? contacts.panicWipe()
                }
            } message: {
                Text("This erases every contact, message, and key. It cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var privacySection: some View {
        Section(localization.localized("settings.privacy_mode")) {
            Toggle(localization.localized("settings.privacy_mode"), isOn: $settings.privacyMode)
        }
    }

    private var securitySection: some View {
        Section(localization.localized("settings.biometric")) {
            Toggle(localization.localized("settings.biometric"), isOn: $settings.biometricEnabled)
            Button(localization.localized("settings.security_dashboard")) {
                showDashboard = true
            }
        }
    }

    private var timersSection: some View {
        Section(localization.localized("settings.auto_lock")) {
            Picker(localization.localized("settings.auto_lock"), selection: $settings.autoLockTimeout) {
                ForEach(AutoLockTimeout.allCases) { value in
                    Text(formatSeconds(value.rawValue)).tag(value)
                }
            }
            Picker(localization.localized("settings.message_ttl"), selection: $settings.messageTTL) {
                ForEach(MessageTTL.allCases) { value in
                    Text(localization.localized(value.localizedKey)).tag(value)
                }
            }
        }
    }

    private var languageSection: some View {
        Section(localization.localized("settings.language")) {
            Picker("", selection: Binding(
                get: { localization.locale.identifier },
                set: { try? localization.setOverride(Locale(identifier: $0)) }
            )) {
                ForEach(LocalizationManager.supported, id: \.identifier) { locale in
                    Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        .tag(locale.identifier)
                }
            }
            Toggle(localization.localized("settings.sound"), isOn: $settings.soundEnabled)
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showWipeConfirm = true
            } label: {
                Text(localization.localized("settings.wipe"))
            }
            NavigationLink(localization.localized("settings.about")) {
                aboutView
            }
        }
    }

    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.localized("app.name")).font(.title).foregroundStyle(.white)
            Text("Version 2.0 (build 1)").foregroundStyle(.gray)
            Text("End-to-end encrypted. Zero-identity. Zero-retention.")
                .foregroundStyle(.gray)
            Spacer()
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
    }

    private func formatSeconds(_ seconds: Int) -> String {
        switch seconds {
        case 0:     return "Immediate"
        case ..<60: return "\(seconds)s"
        case 60:    return "1m"
        case ..<3600: return "\(seconds/60)m"
        default:    return "\(seconds/3600)h"
        }
    }
}
