import SwiftUI

struct SecurityDashboardView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var localization: LocalizationManager

    var body: some View {
        List {
            Section("Connection") {
                row(label: "State", value: String(describing: connection.state))
                row(label: "Room", value: connection.roomId ?? "—")
                row(label: "Safety number", value: connection.safetyNumber ?? "—", monospaced: true)
            }
            Section("Certificate pinning") {
                row(label: "Primary", value: CertificatePinning.primaryPin, monospaced: true)
                row(label: "Backup", value: CertificatePinning.backupPin, monospaced: true)
            }
            Section("Encryption") {
                row(label: "Protocol", value: "Signal Double Ratchet")
                row(label: "Curve", value: "P-256 (CryptoKit)")
                row(label: "AEAD", value: "AES-256-GCM")
                row(label: "PQ", value: "Deferred to Phase 6")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(localization.localized("settings.security_dashboard"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.gray)
            Spacer()
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .footnote)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
