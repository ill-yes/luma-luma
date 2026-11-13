import AppKit
import ColorSync
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

    func supportsBrightnessControl(on display: CGDirectDisplayID) -> Bool {
        write != nil && brightness(of: display) != nil
    }

    func setBrightness(
        _ brightness: Double,
        reference: CGDirectDisplayID,
        followers: [CGDirectDisplayID]
    ) -> BacklightSyncResult {
        guard let write else { return .referenceFailed }
        let level = Float(min(1, max(0, brightness)))
        return BacklightSyncResult.apply(reference: reference, followers: followers) {
            write($0, level) == 0
        }
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

struct ConnectedDisplay {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let identity: UUID?

    var builtIn: Bool { CGDisplayIsBuiltin(id) != 0 }
    var supportsHDR: Bool { screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    var choice: DisplayControlChoice { .init(id: id, name: screen.localizedName) }

    @MainActor
    static func current() -> [Self] {
        let displays: [Self] = NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return nil }
            return Self(id: id, screen: screen, identity: identity(of: id))
        }
        let identityCounts = Dictionary(grouping: displays.compactMap(\.identity), by: { $0 })
        return displays.map { display in
            guard let identity = display.identity, identityCounts[identity]?.count == 1 else {
                return Self(id: display.id, screen: display.screen, identity: nil)
            }
            return display
        }
    }

    private static func identity(of id: CGDirectDisplayID) -> UUID? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)
    }
}
