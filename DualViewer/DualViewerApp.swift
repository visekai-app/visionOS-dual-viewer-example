import SwiftUI

@main
struct DualViewerApp: App {
    @StateObject private var deviceStore: VisionProDeviceStore

    init() {
        ScreenCaptureDeviceUnlocker.allowScreenCaptureDevices()
        _deviceStore = StateObject(wrappedValue: VisionProDeviceStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: deviceStore)
                .frame(minWidth: 1400, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Devices") {
                    deviceStore.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
