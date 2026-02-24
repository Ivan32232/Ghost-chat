import SwiftUI

/// Overlay активного звонка
struct CallView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Timer
            VStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)

                Text(viewModel.callState == .calling ? "Звоним..." : viewModel.callTimer)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Controls
            HStack(spacing: 40) {
                // Mute
                VStack(spacing: 6) {
                    Button {
                        viewModel.toggleMute()
                    } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(viewModel.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    Text(viewModel.isMuted ? "Вкл. микрофон" : "Выкл. микрофон")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }

                // Speaker
                VStack(spacing: 6) {
                    Button {
                        viewModel.toggleSpeaker()
                    } label: {
                        Image(systemName: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(viewModel.isSpeakerOn ? Color.blue.opacity(0.3) : Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    Text(viewModel.isSpeakerOn ? "Динамик" : "На ухо")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }

                // End call
                VStack(spacing: 6) {
                    Button {
                        Task { await viewModel.endCall() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(Color.red)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    Text("Завершить")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color.black.opacity(0.85))
    }
}
