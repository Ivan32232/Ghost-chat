import SwiftUI

/// Баннер входящего звонка
struct IncomingCallView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundStyle(.green)
                    .font(.title3)

                Text("Входящий звонок")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()
            }

            HStack(spacing: 16) {
                // Accept
                Button {
                    Task { await viewModel.acceptCall() }
                } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("Принять")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                // Decline
                Button {
                    Task { await viewModel.declineCall() }
                } label: {
                    HStack {
                        Image(systemName: "phone.down.fill")
                        Text("Отклонить")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
