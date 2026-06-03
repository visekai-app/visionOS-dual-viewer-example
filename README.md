# visionOS Dual Viewer (example)

macOS app that previews and records the video/audio an **Apple Vision Pro**
streams to a Mac over the developer strap. With two headsets connected it shows
both side by side. Pure SwiftUI + AVFoundation, no dependencies.

It works by flipping `kCMIOHardwarePropertyAllowScreenCaptureDevices`, which
exposes the paired headset as an external **muxed** `AVCaptureDevice`.

## Requirements

- macOS 26, Xcode 26.
- Apple Vision Pro with a [developer strap](https://developer.apple.com/visionos/developer-strap/purchase)
  (only tested on **Gen 2**), Developer Mode on, and "Trust This Mac" accepted.

## Run

Open `DualViewer.xcodeproj`, run the `DualViewer` scheme, grant camera + mic
access. Recordings save to `~/Desktop/vp-recordings/`. Change the placeholder
bundle ID `com.example.dualviewer` before distributing.

To capture while no one is wearing it, keep the light-seal sensor covered (e.g.
an [anti-sleep cap](https://www.etsy.com/listing/4387497205/anti-sleep-cap-for-apple-vision-pro))
so the headset doesn't sleep.

## License

MIT — see [LICENSE](LICENSE).
