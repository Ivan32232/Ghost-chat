import SwiftUI

/// Экран выбора языка — флаги, названия, поиск
struct LanguagePickerView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredLanguages: [LocalizationManager.Language] {
        let languages = LocalizationManager.availableLanguages
        guard !searchText.isEmpty else { return languages }

        let query = searchText.lowercased()
        return languages.filter { lang in
            lang.nameNative.lowercased().contains(query)
            || lang.nameEn.lowercased().contains(query)
            || lang.code.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            ForEach(filteredLanguages) { language in
                Button {
                    localization.currentLanguage = language.code
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Text(language.flag)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.nameNative)
                                .foregroundStyle(.white)
                                .font(.body)

                            if language.nameNative != language.nameEn {
                                Text(language.nameEn)
                                    .foregroundStyle(.gray)
                                    .font(.caption)
                            }
                        }

                        Spacer()

                        if language.code == localization.currentLanguage {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.07))
        .navigationTitle("settings.language")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("settings.language.search"))
    }
}
