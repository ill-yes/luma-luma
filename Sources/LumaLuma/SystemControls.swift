import AppKit
import Darwin
import IOKit.ps

struct PowerSnapshot {
    let isOnAC: Bool
    let batteryPercentage: Int?

    static func read() -> Self? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return nil
        }
        let devices = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as [AnyObject]? ?? []
        let battery = devices.lazy.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        var percentage: Int?
        if let current = battery?[kIOPSCurrentCapacityKey] as? Int,
           let maximum = battery?[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
            percentage = Int((100 * Double(current) / Double(maximum)).rounded())
        }
        return Self(isOnAC: source == kIOPSACPowerValue, batteryPercentage: percentage)
    }
}

// macOS doesn't provide a public API for writing Apple display backlight levels.
// This adapter is optional, and a missing framework or unsupported display leaves native keys usable.
@MainActor
final class AppleBrightness {
    private typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let library = DisplayServicesLibrary()
    private lazy var read: Read? = library.resolve("DisplayServicesGetBrightness", as: Read.self)
    private lazy var write: Write? = library.resolve("DisplayServicesSetBrightness", as: Write.self)

    func brightness(of display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard read?(display, &value) == 0, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    func setBrightness(_ brightness: Double, displays: [CGDirectDisplayID]) -> Bool {
        guard let write else { return false }
        let level = Float(min(1, max(0, brightness)))
        var wrote = false
        for display in displays {
            if write(display, level) == 0 {
                wrote = true
            }
        }
        return wrote
    }
}

private final class DisplayServicesLibrary {
    private let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY | RTLD_LOCAL
    )

    func resolve<T>(_ symbol: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    deinit {
        if let handle { dlclose(handle) }
    }
}

extension NSScreen {
    private var lumaLumaDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screens(in scope: DisplayScope) -> [(id: CGDirectDisplayID, screen: NSScreen)] {
        screens.compactMap { screen in
            guard let id = screen.lumaLumaDisplayID else { return nil }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            switch scope {
            case .all: return (id, screen)
            case .builtIn: return builtIn ? (id, screen) : nil
            case .external: return builtIn ? nil : (id, screen)
            }
        }
    }
}
