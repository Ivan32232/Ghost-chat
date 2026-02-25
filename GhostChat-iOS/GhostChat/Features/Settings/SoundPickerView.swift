import SwiftUI

/// Экран выбора звука — рингтон или звук сообщения
/// Показывает список с превью по нажатию
struct SoundPickerView: View {
    let title: String
    let sounds: [SoundLibrary.Sound]
    @Binding var selectedId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(sounds) { sound in
                Button {
                    SoundLibrary.playPreview(sound)
                    selectedId = sound.id
                } label: {
                    HStack {
                        Text(sound.nameKey)
                            .foregroundStyle(.white)

                        Spacer()

                        if sound.id == selectedId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.07))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
