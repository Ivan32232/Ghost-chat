import SwiftUI

struct AboutView: View {
    @EnvironmentObject var localization: LocalizationManager
    @Environment(\.openURL) private var openURL

    private let websiteURL = URL(string: "https://ghostchat.one")!
    private let privacyURL = URL(string: "https://ghostchat.one/privacy")!
    private let githubURL  = URL(string: "https://github.com/Ivan32232/Ghost-chat")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                    Text(localization.localized("app.name"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Version \(appVersion) (build \(appBuild))")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                    Text("End-to-end encrypted. Zero-identity. Zero-retention.")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.black)
            }

            Section {
                link(label: "about.website", systemImage: "globe", url: websiteURL)
                link(label: "about.privacy_policy", systemImage: "hand.raised.fill", url: privacyURL)
                link(label: "about.source_code", systemImage: "chevron.left.forwardslash.chevron.right", url: githubURL)
            }

            Section {
                HStack {
                    Spacer()
                    Text(localization.localized("about.made_by"))
                        .font(.footnote)
                        .foregroundStyle(.gray)
                    Spacer()
                }
                .listRowBackground(Color.black)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(localization.localized("settings.about"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func link(label: String, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(.white).frame(width: 24)
                Text(localization.localized(label)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.gray)
            }
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
