import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var localization: LocalizationManager
    @EnvironmentObject var contacts: ContactManager
    @Environment(\.dismiss) private var dismiss

    @State private var showWipeConfirm = false
    @State private var showDashboard = false
    @State private var showAbout = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                privacySection
                biometricSection
                notificationsSection
                securityDashboardSection
                timersSection
                languageSection
                dangerSection
                aboutSection
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
            .navigationDestination(isPresented: $showDashboard) { SecurityDashboardView() }
            .navigationDestination(isPresented: $showAbout) { AboutView() }
            .alert(localization.localized("settings.wipe"), isPresented: $showWipeConfirm) {
                Button(localization.localized("action.cancel"), role: .cancel) {}
                Button(localization.localized("settings.wipe"), role: .destructive) {
                    try? contacts.panicWipe()
                }
            } message: {
                Text(localization.localized("settings.wipe_desc"))
            }
            .alert(
                localization.localized("settings.notifications_denied_title"),
                isPresented: $notificationsDenied
            ) {
                Button(localization.localized("action.done"), role: .cancel) {}
            } message: {
                Text(localization.localized("settings.notifications_denied_message"))
            }
        }
    }

    // MARK: - Sections

    private var privacySection: some View {
        Section {
            SettingRow(
                label: localization.localized("settings.privacy_mode"),
                description: localization.localized("settings.privacy_mode_desc")
            ) {
                Toggle("", isOn: $settings.privacyMode).labelsHidden()
            }
        }
    }

    private var biometricSection: some View {
        Section {
            SettingRow(
                label: localization.localized("settings.biometric"),
                description: localization.localized("settings.biometric_desc")
            ) {
                Toggle("", isOn: $settings.biometricEnabled).labelsHidden()
            }
        }
    }

    /// Notifications opt-in. Default OFF; tapping ON triggers the iOS APNs
    /// permission prompt. If denied, the toggle bounces back to OFF and we
    /// surface a one-shot alert pointing the user to iOS Settings.
    private var notificationsSection: some View {
        Section {
            SettingRow(
                label: localization.localized("settings.notifications"),
                description: localization.localized("settings.notifications_desc")
            ) {
                Toggle("", isOn: notificationsBinding).labelsHidden()
            }
        }
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { newValue in
                if newValue {
                    Task { @MainActor in
                        let delegate = UIApplication.shared.delegate as? AppDelegate
                        let granted = (await delegate?.requestNotificationsAuthorization()) ?? false
                        if granted {
                            settings.notificationsEnabled = true
                        } else {
                            settings.notificationsEnabled = false
                            notificationsDenied = true
                        }
                    }
                } else {
                    settings.notificationsEnabled = false
                }
            }
        )
    }

    private var securityDashboardSection: some View {
        Section {
            Button { showDashboard = true } label: {
                SettingRow(
                    label: localization.localized("settings.security_dashboard"),
                    description: localization.localized("settings.security_dashboard_desc")
                ) {
                    Image(systemName: "chevron.right").foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var timersSection: some View {
        Section {
            SettingRow(
                label: localization.localized("settings.auto_lock"),
                description: localization.localized("settings.auto_lock_desc")
            ) {
                Picker("", selection: $settings.autoLockTimeout) {
                    ForEach(AutoLockTimeout.allCases) { value in
                        Text(formatSeconds(value.rawValue)).tag(value)
                    }
                }.labelsHidden()
            }
            SettingRow(
                label: localization.localized("settings.message_ttl"),
                description: localization.localized("settings.message_ttl_desc")
            ) {
                Picker("", selection: $settings.messageTTL) {
                    ForEach(MessageTTL.allCases) { value in
                        Text(localization.localized(value.localizedKey)).tag(value)
                    }
                }.labelsHidden()
            }
        }
    }

    private var languageSection: some View {
        Section {
            HStack {
                Text(localization.localized("settings.language"))
                    .foregroundStyle(.white)
                Spacer()
                Picker("", selection: Binding(
                    get: { localization.locale.identifier },
                    set: { try? localization.setOverride(Locale(identifier: $0)) }
                )) {
                    ForEach(LocalizationManager.supported, id: \.identifier) { locale in
                        Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }.labelsHidden()
            }
            SettingRow(
                label: localization.localized("settings.sound"),
                description: localization.localized("settings.sound_desc")
            ) {
                Toggle("", isOn: $settings.soundEnabled).labelsHidden()
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showWipeConfirm = true
            } label: {
                SettingRow(
                    label: localization.localized("settings.wipe"),
                    description: localization.localized("settings.wipe_desc"),
                    labelColor: .red
                ) { EmptyView() }
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSection: some View {
        Section {
            Button { showAbout = true } label: {
                SettingRow(
                    label: localization.localized("settings.about"),
                    description: nil
                ) {
                    Image(systemName: "chevron.right").foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
        }
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

/// Two-line settings row: primary label on top, gray description below, trailing accessory.
private struct SettingRow<Accessory: View>: View {
    let label: String
    let description: String?
    var labelColor: Color = .white
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .foregroundStyle(labelColor)
                if let description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            accessory()
        }
    }
}
