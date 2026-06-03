import SwiftUI

struct ContentView: View {
    @ObservedObject var store: VisionProDeviceStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if store.controllers.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(store.controllers) { controller in
                            DeviceTileView(controller: controller)
                                .frame(minWidth: 672, idealWidth: 672, maxWidth: 840)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Vision Pro Streams")
                .font(.title2.weight(.semibold))

            Text(store.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let lastRefreshDate = store.lastRefreshDate {
                Text(lastRefreshDate, style: .time)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button("Refresh Devices") {
                store.refreshDevices()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("No Vision Pro muxed streams")
                .font(.title3.weight(.medium))

            Text(store.statusMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            Button("Refresh Devices") {
                store.refreshDevices()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct DeviceTileView: View {
    @ObservedObject var controller: VisionProCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                CapturePreviewView(controller: controller)
                    .aspectRatio(16 / 9, contentMode: .fit)

                if !controller.isPreviewing {
                    Text("Preview stopped")
                        .foregroundStyle(.secondary)
                }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Text(controller.deviceName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if controller.isRecording {
                    RecordingIndicator()
                }

                Spacer()

                Button(controller.isPreviewing ? "Stop Preview" : "Start Preview") {
                    controller.togglePreview()
                }

                Button(controller.isRecording ? "Stop Record" : "Record") {
                    controller.toggleRecording()
                }
                .disabled(!controller.isPreviewing && controller.isRecording)

                Button(controller.isAudioMonitoringEnabled ? "Mute Stream" : "Monitor Audio") {
                    controller.toggleAudioMonitoring()
                }

                AudioLevelMeterView(
                    level: controller.audioLevel,
                    isActive: controller.isAudioMonitoringEnabled
                )
            }

            if let lastRecordingURL = controller.lastRecordingURL {
                Text(lastRecordingURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let audioStatusMessage = controller.audioStatusMessage {
                Text(audioStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { controller.startPreview() }
        .onDisappear { controller.stopPreview() }
    }
}

struct AudioLevelMeterView: View {
    let level: Float
    let isActive: Bool

    private let barCount = 12

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: 4, height: CGFloat(4 + index))
            }
        }
        .frame(width: 72, height: 18, alignment: .center)
        .opacity(isActive ? 1 : 0.35)
        .accessibilityLabel("Audio level")
        .accessibilityValue(isActive ? "\(Int(level * 100)) percent" : "muted")
    }

    private func color(for index: Int) -> Color {
        guard isActive, Float(index + 1) / Float(barCount) <= level else {
            return .secondary.opacity(0.35)
        }

        switch index {
        case 0..<7:
            return .green
        case 7..<10:
            return .yellow
        default:
            return .red
        }
    }
}

struct RecordingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("REC")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
        .accessibilityLabel("Recording")
    }
}
