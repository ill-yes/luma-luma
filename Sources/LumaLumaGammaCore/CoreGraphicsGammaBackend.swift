import ColorSync
import CoreGraphics
import Foundation

struct CoreGraphicsGammaBackend: GammaBackend {
    func identity(of display: UInt32) -> UUID? {
        guard CGDisplayIsBuiltin(display) != 0,
              CGDisplayIsOnline(display) != 0,
              CGDisplayIsActive(display) != 0,
              let displayUUID = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, displayUUID) as String? else { return nil }
        return UUID(uuidString: string)
    }

    func display(for identity: UUID) -> UInt32? {
        guard let displayUUID = CFUUIDCreateFromString(nil, identity.uuidString as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(displayUUID)
        return self.identity(of: id) == identity ? id : nil
    }

    func read(from display: UInt32, identity: UUID) -> GammaCurve? {
        guard self.identity(of: display) == identity else { return nil }
        let capacity = CGDisplayGammaTableCapacity(display)
        guard (2...4096).contains(capacity) else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success,
              (2...capacity).contains(count), self.identity(of: display) == identity else { return nil }
        return GammaCurve(
            red: Array(red.prefix(Int(count))),
            green: Array(green.prefix(Int(count))),
            blue: Array(blue.prefix(Int(count)))
        )
    }

    func write(_ curve: GammaCurve, to display: UInt32, identity: UUID) -> Bool {
        guard self.identity(of: display) == identity else { return false }
        return CGSetDisplayTransferByTable(display, UInt32(curve.count), curve.red, curve.green, curve.blue) == .success
    }
}
