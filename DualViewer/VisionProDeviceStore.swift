@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VisionProDeviceStore: NSObject, ObservableObject {
    @Published private(set) var controllers: [VisionProCaptureController] = []
    @Published private(set) var cameraAuthorizationStatus: AVAuthorizationStatus
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var statusMessage: String = "Waiting for camera permission and Vision Pro devices."

    override init() {
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceListDidChange(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceListDidChange(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )

        requestCameraAccess()
        scheduleStartupRescans()
    }

    // Capture devices register asynchronously after the unlock flag is set, so
    // re-scan a few times on startup to catch them. BOUNDED (not a perpetual
    // loop) and enumeration-only — it never restarts active sessions, so it
    // doesn't thrash a device's connection the way continuous polling did.
    private func scheduleStartupRescans() {
        Task { @MainActor [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.controllers.count >= 2 { return }
                self.refreshDevices()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func requestCameraAccess() {
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch cameraAuthorizationStatus {
        case .authorized:
            refreshDevices()
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                statusMessage = granted
                    ? "Camera access granted. Refreshing Vision Pro devices."
                    : "Camera access was denied. Enable camera access in System Settings."
                refreshDevices()
                // Force a clean restart for any controller whose preview was
                // started (frameless) before access was granted.
                if granted {
                    controllers.forEach { $0.stopPreview(); $0.startPreview() }
                }
            }
        case .denied, .restricted:
            statusMessage = "Camera access is blocked. Enable camera access in System Settings."
            refreshDevices()
        @unknown default:
            statusMessage = "Unknown camera authorization state. Refreshing devices anyway."
            refreshDevices()
        }
    }

    func refreshDevices() {
        ScreenCaptureDeviceUnlocker.allowScreenCaptureDevices()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        )
        let visionProDevices = discovery.devices
            .filter { $0.hasMediaType(.muxed) }
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }

        let existing = Dictionary(uniqueKeysWithValues: controllers.map { ($0.id, $0) })
        let liveIDs = Set(visionProDevices.map(\.uniqueID))

        for controller in controllers where !liveIDs.contains(controller.id) {
            controller.stopRecording()
            controller.stopPreview()
        }

        controllers = visionProDevices.map { device in
            existing[device.uniqueID] ?? VisionProCaptureController(device: device)
        }

        lastRefreshDate = Date()
        statusMessage = statusText(deviceCount: controllers.count)
    }

    @objc private func deviceListDidChange(_ notification: Notification) {
        Task { @MainActor in
            refreshDevices()
        }
    }

    private func statusText(deviceCount: Int) -> String {
        if cameraAuthorizationStatus == .notDetermined {
            return "Waiting for camera permission."
        }

        if cameraAuthorizationStatus != .authorized {
            return "Camera access is not authorized. Device discovery can still refresh, but preview may fail."
        }

        switch deviceCount {
        case 0:
            return "No muxed external Vision Pro devices found. Connect a Vision Pro and refresh."
        case 1:
            return "1 Vision Pro device found."
        default:
            return "\(deviceCount) Vision Pro devices found."
        }
    }
}
