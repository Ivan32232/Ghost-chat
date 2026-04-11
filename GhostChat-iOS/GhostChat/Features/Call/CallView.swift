import SwiftUI
import AVKit
import UIKit

/// Telegram-style audio output route picker.
/// Wraps AVRoutePickerView so the user can pick between earpiece / speaker /
/// Bluetooth headset / AirPods from a system sheet — same UX as Telegram.
private struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .white
        view.tintColor = .white
        view.backgroundColor = .clear
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

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

                // Audio output route — Telegram-style picker
                // System AVRoutePickerView shows all available outputs (earpiece,
                // speaker, Bluetooth headsets, AirPods, CarPlay).
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 72, height: 72)
                        // Visual icon layer — AVRoutePickerView receives the tap
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                        AudioRoutePickerButton()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                    }
                    Text("call.audioOutput")
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
