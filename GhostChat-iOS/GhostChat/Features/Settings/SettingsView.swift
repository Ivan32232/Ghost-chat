import SwiftUI

/// Экран настроек — как в Telegram, настраиваемые параметры приложения
struct SettingsView: View {
    @EnvironmentObject var biometricAuth: BiometricAuthService
    @EnvironmentObject var localization: LocalizationManager
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false
    @State private var showDestroyConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Язык
                Section {
                    NavigationLink {
                        LanguagePickerView()
                    } label: {
                        Label {
                            Text("settings.language")
                        } icon: {
                            Text(localization.currentFlag)
                        }
                        Spacer()
                        Text(localization.currentLanguageName)
                            .foregroundStyle(.gray)
                            .font(.subheadline)
                    }
                } header: {
                    Text("settings.language.header")
                }

                // MARK: - Безопасность
                Section {
                    // Face ID / Touch ID
                    if BiometricAuthService.isAvailable {
                        Toggle(isOn: Binding(
                            get: { biometricAuth.isEnabled },
                            set: { biometricAuth.setEnabled($0) }
                        )) {
                            Label {
                                Text(biometricAuth.biometricName)
                            } icon: {
                                Image(systemName: biometricIcon)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .tint(.green)
                    }

                    // Автоблокировка
                    if biometricAuth.isEnabled {
                        HStack {
                            Label {
                                Text("settings.autolock")
                            } icon: {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("settings.autolock.background")
                                .foregroundStyle(.gray)
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("settings.security")
                } footer: {
                    if BiometricAuthService.isAvailable {
                        Text("settings.security.footer")
                    }
                }

                // MARK: - Приватность
                Section {
                    // Режим приватности (relay)
                    Toggle(isOn: $viewModel.privacyMode) {
                        Label {
                            Text("settings.privacy.relay")
                        } icon: {
                            Image(systemName: "shield.checkered")
                                .foregroundStyle(.green)
                        }
                    }
                    .tint(.green)

                    // Таймер автоудаления
                    Picker(selection: $viewModel.autoDeleteMinutes) {
                        Text("settings.autodelete.1").tag(1)
                        Text("settings.autodelete.3").tag(3)
                        Text("settings.autodelete.5").tag(5)
                        Text("settings.autodelete.10").tag(10)
                        Text("settings.autodelete.30").tag(30)
                    } label: {
                        Label {
                            Text("settings.autodelete")
                        } icon: {
                            Image(systemName: "timer")
                                .foregroundStyle(.purple)
                        }
                    }

                    // Скриншоты — уведомления
                    Toggle(isOn: $viewModel.screenshotNotifications) {
                        Label {
                            Text("settings.screenshot.notify")
                        } icon: {
                            Image(systemName: "camera.viewfinder")
                                .foregroundStyle(.red)
                        }
                    }
                    .tint(.green)
                } header: {
                    Text("settings.privacy")
                } footer: {
                    Text("settings.privacy.footer")
                }

                // MARK: - Звуки и уведомления
                Section {
                    // Звук сообщений вкл/выкл
                    Toggle(isOn: $viewModel.messageSoundEnabled) {
                        Label {
                            Text("settings.sound")
                        } icon: {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.indigo)
                        }
                    }
                    .tint(.green)

                    // Выбор звука сообщения
                    if viewModel.messageSoundEnabled {
                        NavigationLink {
                            SoundPickerView(
                                title: String(localized: "settings.sound.message"),
                                sounds: SoundLibrary.messageSounds,
                                selectedId: $viewModel.messageSoundId
                            )
                        } label: {
                            Label {
                                Text("settings.sound.message")
                            } icon: {
                                Image(systemName: "bell.fill")
                                    .foregroundStyle(.indigo)
                            }
                            Spacer()
                            Text(SoundLibrary.messageSound(forId: viewModel.messageSoundId).nameKey)
                                .foregroundStyle(.gray)
                                .font(.subheadline)
                        }
                    }

                    // Выбор рингтона
                    NavigationLink {
                        SoundPickerView(
                            title: String(localized: "settings.sound.ringtone"),
                            sounds: SoundLibrary.ringtones,
                            selectedId: $viewModel.ringtoneId
                        )
                    } label: {
                        Label {
                            Text("settings.sound.ringtone")
                        } icon: {
                            Image(systemName: "phone.badge.waveform.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text(SoundLibrary.ringtone(forId: viewModel.ringtoneId).nameKey)
                            .foregroundStyle(.gray)
                            .font(.subheadline)
                    }

                    // Вибрация
                    Toggle(isOn: $viewModel.vibrationEnabled) {
                        Label {
                            Text("settings.vibration")
                        } icon: {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(.cyan)
                        }
                    }
                    .tint(.green)
                } header: {
                    Text("settings.sounds")
                }

                // MARK: - Данные
                Section {
                    // Удалить все контакты
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label {
                            Text("settings.data.deleteContacts")
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.minus")
                                .foregroundStyle(.red)
                        }
                    }

                    // Удалить всё (panic button)
                    Button(role: .destructive) {
                        showDestroyConfirmation = true
                    } label: {
                        Label {
                            Text("settings.data.destroyAll")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("settings.data")
                } footer: {
                    Text("settings.data.footer")
                }

                // MARK: - О приложении
                Section {
                    HStack {
                        Label {
                            Text("settings.about.version")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.gray)
                    }

                    HStack {
                        Label {
                            Text("settings.about.protocol")
                        } icon: {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                        Text("Double Ratchet v\(GhostCrypto.protocolVersion)")
                            .foregroundStyle(.gray)
                    }

                    HStack {
                        Label {
                            Text("settings.about.encryption")
                        } icon: {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                        Text("AES-256-GCM + P-256")
                            .foregroundStyle(.gray)
                    }

                    if GhostCrypto.isPQAvailable {
                        HStack {
                            Label {
                                Text("settings.about.pq")
                            } icon: {
                                Image(systemName: "atom")
                                    .foregroundStyle(.gray)
                            }
                            Spacer()
                            Text("ML-KEM768")
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("settings.about")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.07))
            .navigationTitle("settings.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("settings.done")
                            .fontWeight(.semibold)
                    }
                }
            }
            .alert("settings.data.deleteContacts.confirm", isPresented: $showDeleteConfirmation) {
                Button("settings.delete", role: .destructive) {
                    try? DatabaseService.shared.deleteAll()
                }
                Button("settings.cancel", role: .cancel) {}
            }
            .alert("settings.data.destroyAll.confirm", isPresented: $showDestroyConfirmation) {
                Button("settings.destroy", role: .destructive) {
                    IdentityKeyService.shared.destroy()
                    DatabaseService.destroy()
                    biometricAuth.setEnabled(false)
                }
                Button("settings.cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Helpers

    private var biometricIcon: String {
        switch BiometricAuthService.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return "lock"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
