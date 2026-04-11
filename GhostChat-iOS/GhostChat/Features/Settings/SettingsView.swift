import SwiftUI

/// Экран настроек — как в Telegram, настраиваемые параметры приложения
struct SettingsView: View {
    @EnvironmentObject var biometricAuth: BiometricAuthService
    @EnvironmentObject var localization: LocalizationManager
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false
    @State private var showDestroyConfirmation = false
    @State private var showDeleteHistoryConfirmation = false
    @State private var showDeleteSavedConfirmation = false
    @State private var showRemovePinConfirmation = false

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
                    // PIN Code
                    if !biometricAuth.isPinSet {
                        NavigationLink {
                            SetPinView(auth: biometricAuth, mode: .create)
                        } label: {
                            Label {
                                Text("pin.set")
                            } icon: {
                                Image(systemName: "lock.rectangle")
                                    .foregroundStyle(.blue)
                            }
                        }
                    } else {
                        NavigationLink {
                            SetPinView(auth: biometricAuth, mode: .change)
                        } label: {
                            Label {
                                Text("pin.change")
                            } icon: {
                                Image(systemName: "lock.rectangle")
                                    .foregroundStyle(.blue)
                            }
                        }

                        Button(role: .destructive) {
                            showRemovePinConfirmation = true
                        } label: {
                            Label {
                                Text("pin.remove")
                            } icon: {
                                Image(systemName: "lock.open")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    // Face ID / Touch ID — only when PIN is set
                    if biometricAuth.isPinSet && BiometricAuthService.isAvailable {
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
                    if biometricAuth.isPinSet || biometricAuth.isEnabled {
                        Picker(selection: $biometricAuth.autoLockSeconds) {
                            Text("settings.autolock.instant").tag(0)
                            Text("settings.autolock.15s").tag(15)
                            Text("settings.autolock.30s").tag(30)
                            Text("settings.autolock.1m").tag(60)
                            Text("settings.autolock.5m").tag(300)
                        } label: {
                            Label {
                                Text("settings.autolock")
                            } icon: {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("settings.security")
                } footer: {
                    Text("settings.security.pin.footer")
                }

                // MARK: - Приватность
                Section {
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

                // MARK: - История чатов
                Section {
                    Toggle(isOn: $viewModel.saveMessageHistory) {
                        Label {
                            Text("settings.history.save")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.blue)
                        }
                    }
                    .tint(.green)

                    // Saved Messages (Избранное)
                    Toggle(isOn: Binding(
                        get: { viewModel.savedMessagesEnabled },
                        set: { newValue in
                            if newValue {
                                viewModel.savedMessagesEnabled = true
                                dismiss()
                                viewModel.openSavedMessages()
                            } else {
                                // Can't just disable — must delete messages first
                                showDeleteSavedConfirmation = true
                            }
                        }
                    )) {
                        Label {
                            Text("saved.title")
                        } icon: {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.purple)
                        }
                    }
                    .tint(.green)

                    if viewModel.saveMessageHistory {
                        Button(role: .destructive) {
                            showDeleteHistoryConfirmation = true
                        } label: {
                            Label {
                                Text("settings.history.deleteAll")
                            } icon: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                } header: {
                    Text("settings.history")
                } footer: {
                    Text("settings.history.footer")
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
            .background(Color(white: 0.04)) // #0a0a0a
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
                    try? ContactStore().deleteAll()
                    try? MessageStore().deleteAll()
                    dismiss()
                    viewModel.performHardReset()
                }
                Button("settings.cancel", role: .cancel) {}
            }
            .alert("settings.history.deleteAll", isPresented: $showDeleteHistoryConfirmation) {
                Button("settings.destroy", role: .destructive) {
                    // Clean up files before hard reset
                    biometricAuth.removePin()
                    IdentityKeyService.shared.destroy()
                    let filesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("files")
                    if let dir = filesDir { try? FileManager.default.removeItem(at: dir) }
                    let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("ghost_debug.log")
                    if let log = logFile { try? FileManager.default.removeItem(at: log) }
                    dismiss()
                    // performHardReset handles DB close → destroy → recreate
                    viewModel.performHardReset()
                }
                Button("settings.cancel", role: .cancel) {}
            } message: {
                Text("settings.history.deleteAll.warning")
            }
            .alert("settings.data.destroyAll.confirm", isPresented: $showDestroyConfirmation) {
                Button("settings.destroy", role: .destructive) {
                    IdentityKeyService.shared.destroy()
                    DatabaseService.destroy()
                    biometricAuth.removePin()
                    dismiss()
                    viewModel.performHardReset()
                }
                Button("settings.cancel", role: .cancel) {}
            }
            .alert("saved.disable.confirm", isPresented: $showDeleteSavedConfirmation) {
                Button("settings.delete", role: .destructive) {
                    try? MessageStore().deleteForContact(ChatViewModel.savedMessagesContactId)
                    viewModel.savedMessagesEnabled = false
                }
                Button("settings.cancel", role: .cancel) {}
            }
            .alert("pin.remove.confirm", isPresented: $showRemovePinConfirmation) {
                Button("pin.remove", role: .destructive) {
                    biometricAuth.removePin()
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
