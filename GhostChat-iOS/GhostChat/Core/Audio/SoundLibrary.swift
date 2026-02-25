import AudioToolbox
import AVFoundation
import SwiftUI

/// Библиотека доступных системных звуков для рингтонов и уведомлений
/// Использует iOS System Sound Services (AudioToolbox)
enum SoundLibrary {

    // MARK: - Sound Definition

    struct Sound: Identifiable, Equatable, @unchecked Sendable {
        let id: String                    // Уникальный ключ для персистенции
        let nameKey: LocalizedStringKey   // Локализованное имя
        let systemSoundID: SystemSoundID
        let isDefault: Bool

        static func == (lhs: Sound, rhs: Sound) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Ringtones (для входящих звонков — повторяются таймером)

    static let ringtones: [Sound] = [
        Sound(id: "ringtone.anticipate",  nameKey: "sound.anticipate",  systemSoundID: 1320, isDefault: false),
        Sound(id: "ringtone.bloom",       nameKey: "sound.bloom",       systemSoundID: 1321, isDefault: false),
        Sound(id: "ringtone.calypso",     nameKey: "sound.calypso",     systemSoundID: 1322, isDefault: false),
        Sound(id: "ringtone.chooChoo",    nameKey: "sound.chooChoo",    systemSoundID: 1323, isDefault: false),
        Sound(id: "ringtone.descent",     nameKey: "sound.descent",     systemSoundID: 1324, isDefault: false),
        Sound(id: "ringtone.fanfare",     nameKey: "sound.fanfare",     systemSoundID: 1325, isDefault: true),
        Sound(id: "ringtone.ladder",      nameKey: "sound.ladder",      systemSoundID: 1326, isDefault: false),
        Sound(id: "ringtone.minuet",      nameKey: "sound.minuet",      systemSoundID: 1327, isDefault: false),
        Sound(id: "ringtone.newsFlash",   nameKey: "sound.newsFlash",   systemSoundID: 1328, isDefault: false),
        Sound(id: "ringtone.noir",        nameKey: "sound.noir",        systemSoundID: 1329, isDefault: false),
        Sound(id: "ringtone.sherwood",    nameKey: "sound.sherwood",    systemSoundID: 1330, isDefault: false),
        Sound(id: "ringtone.spell",       nameKey: "sound.spell",       systemSoundID: 1331, isDefault: false),
        Sound(id: "ringtone.suspense",    nameKey: "sound.suspense",    systemSoundID: 1332, isDefault: false),
        Sound(id: "ringtone.telegraph",   nameKey: "sound.telegraph",   systemSoundID: 1333, isDefault: false),
        Sound(id: "ringtone.tiptoes",     nameKey: "sound.tiptoes",     systemSoundID: 1334, isDefault: false),
        Sound(id: "ringtone.typewriters", nameKey: "sound.typewriters", systemSoundID: 1335, isDefault: false),
        Sound(id: "ringtone.update",      nameKey: "sound.update",      systemSoundID: 1336, isDefault: false),
    ]

    // MARK: - Message Sounds (для входящих сообщений — однократные)

    static let messageSounds: [Sound] = [
        Sound(id: "msg.none",      nameKey: "sound.none",       systemSoundID: 0,    isDefault: false),
        Sound(id: "msg.tock",      nameKey: "sound.tock",       systemSoundID: 1104, isDefault: false),
        Sound(id: "msg.tink",      nameKey: "sound.tink",       systemSoundID: 1103, isDefault: false),
        Sound(id: "msg.pop",       nameKey: "sound.pop",        systemSoundID: 1105, isDefault: false),
        Sound(id: "msg.received",  nameKey: "sound.received",   systemSoundID: 1003, isDefault: true),
        Sound(id: "msg.sent",      nameKey: "sound.sent",       systemSoundID: 1004, isDefault: false),
        Sound(id: "msg.tweet",     nameKey: "sound.tweet",      systemSoundID: 1016, isDefault: false),
        Sound(id: "msg.anticipate",nameKey: "sound.anticipate", systemSoundID: 1320, isDefault: false),
        Sound(id: "msg.bloom",     nameKey: "sound.bloom",      systemSoundID: 1321, isDefault: false),
        Sound(id: "msg.calypso",   nameKey: "sound.calypso",    systemSoundID: 1322, isDefault: false),
        Sound(id: "msg.descent",   nameKey: "sound.descent",    systemSoundID: 1324, isDefault: false),
        Sound(id: "msg.ladder",    nameKey: "sound.ladder",     systemSoundID: 1326, isDefault: false),
        Sound(id: "msg.minuet",    nameKey: "sound.minuet",     systemSoundID: 1327, isDefault: false),
        Sound(id: "msg.noir",      nameKey: "sound.noir",       systemSoundID: 1329, isDefault: false),
        Sound(id: "msg.telegraph", nameKey: "sound.telegraph",  systemSoundID: 1333, isDefault: false),
    ]

    // MARK: - Lookup

    static func ringtone(forId id: String) -> Sound {
        ringtones.first { $0.id == id } ?? ringtones.first { $0.isDefault }!
    }

    static func messageSound(forId id: String) -> Sound {
        messageSounds.first { $0.id == id } ?? messageSounds.first { $0.isDefault }!
    }

    static var defaultRingtoneId: String {
        ringtones.first { $0.isDefault }!.id
    }

    static var defaultMessageSoundId: String {
        messageSounds.first { $0.isDefault }!.id
    }

    // MARK: - Playback

    /// Воспроизвести превью звука
    static func playPreview(_ sound: Sound) {
        guard sound.systemSoundID != 0 else { return }
        AudioServicesPlaySystemSound(sound.systemSoundID)
    }

    /// Воспроизвести звук сообщения (с вибрацией если включена)
    static func playMessageSound(_ sound: Sound, withVibration: Bool) {
        if sound.systemSoundID != 0 {
            if withVibration {
                AudioServicesPlayAlertSound(sound.systemSoundID)
            } else {
                AudioServicesPlaySystemSound(sound.systemSoundID)
            }
        } else if withVibration {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Воспроизвести рингтон (однократно — таймер управляет повтором)
    static func playRingtoneSound(_ sound: Sound) {
        guard sound.systemSoundID != 0 else { return }
        AudioServicesPlayAlertSound(sound.systemSoundID)
    }
}
