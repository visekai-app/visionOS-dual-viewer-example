import CoreMediaIO
import Foundation

enum ScreenCaptureDeviceUnlocker {
    static func allowScreenCaptureDevices() {
        setHardwareFlag(CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices))
    }

    private static func setHardwareFlag(_ selector: CMIOObjectPropertySelector) {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1

        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }
}
