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

                if viewModel.callState == .calling {
                    Text("call.calling")
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                } else {
                    Text(viewModel.callTimer)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            // Controls
            HStack(spacing: 36) {
                // Mute
                VStack(spacing: 8) {
                    Button {
                        viewModel.toggleMute()
                    } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title)
                            .frame(width: 72, height: 72)
                            .background(viewModel.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    Text(LocalizedStringKey(viewModel.isMuted ? "call.unmute" : "call.mute"))
                        .font(.caption)
                        .foregroundStyle(.gray)
                }

                // Speaker
                VStack(spacing: 8) {
                    Button {
                        viewModel.toggleSpeaker()
                    } label: {
                        Image(systemName: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill")
                            .font(.title)
                            .frame(width: 72, height: 72)
                            .background(viewModel.isSpeakerOn ? Color(white: 0.88).opacity(0.3) : Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    Text(LocalizedStringKey(viewModel.isSpeakerOn ? "call.speaker" : "call.earpiece"))
                        .font(.caption)
                        .foregroundStyle(.gray)
                }

                // End call
                VStack(spacing: 8) {
                    Button {
                        Task { await viewModel.endCall() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.title)
                            .frame(width: 72, height: 72)
                            .background(Color.red)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    Text("call.end")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color.black.opacity(0.85))
    }
}
