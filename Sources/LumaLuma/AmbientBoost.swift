import Foundation
import IOKit

enum AmbientSensitivity: String, Codable, CaseIterable {
    case standard
    case high
    case low

    var title: String { rawValue.capitalized }

    var activationLux: Double {
        switch self {
        case .standard: 3_000
        case .high: 1_500
        case .low: 6_000
        }
    }

    var deactivationLux: Double {
        switch self {
        case .standard: 2_000
        case .high: 1_000
        case .low: 4_000
        }
    }
}

struct AmbientBoostPolicy {
    static let pollInterval: TimeInterval = 2

    private(set) var isSuppressed = false
    private var wantsBoost = false
    private var sensitivity: AmbientSensitivity?
    private var brightSince: ContinuousClock.Instant?
    private var darkSince: ContinuousClock.Instant?
    private var lastValidSample: ContinuousClock.Instant?

    mutating func update(
        lux: Double?,
        eligible: Bool,
        nativeBrightness: Double?,
        sensitivity: AmbientSensitivity,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        if self.sensitivity != sensitivity {
            self.sensitivity = sensitivity
            brightSince = nil
            darkSince = nil
        }
        let validBrightness = nativeBrightness.flatMap { (0...1).contains($0) ? $0 : nil }
        let atNativeMaximum = (validBrightness ?? 0) >= 0.999
        if wantsBoost, validBrightness != nil, !atNativeMaximum {
            suppressUntilDark()
        }
        let canBoost = eligible && atNativeMaximum
        if !canBoost {
            wantsBoost = false
            brightSince = nil
        }
        if let lastValidSample, lastValidSample.duration(to: now) >= .seconds(6) {
            pause()
        }
        guard let lux, lux.isFinite, lux >= 0 else {
            brightSince = nil
            darkSince = nil
            return wantsBoost
        }
        lastValidSample = now

        if lux <= sensitivity.deactivationLux, wantsBoost || isSuppressed {
            let since = darkSince ?? now
            darkSince = since
            if since.duration(to: now) >= .seconds(8) {
                wantsBoost = false
                isSuppressed = false
                darkSince = nil
            }
        } else {
            darkSince = nil
        }

        guard canBoost, !isSuppressed, !wantsBoost, lux >= sensitivity.activationLux else {
            brightSince = nil
            return wantsBoost
        }
        let since = brightSince ?? now
        brightSince = since
        if since.duration(to: now) >= .seconds(4) {
            wantsBoost = true
            brightSince = nil
        }
        return wantsBoost
    }

    mutating func suppressUntilDark() {
        isSuppressed = true
        pause()
    }

    mutating func pause() {
        wantsBoost = false
        brightSince = nil
        darkSince = nil
        lastValidSample = nil
    }
}

enum AmbientLightSensor {
    static func readLux() -> Double? {
        // These driver properties describe the integrated sensor on supported Macs.
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var foundSensor = false
        var lux: Double?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if property("Product", on: service) as? String == "als",
               property("Transport", on: service) as? String == "SPU",
               number("PrimaryUsagePage", on: service) == 0xFF00,
               number("PrimaryUsage", on: service) == 4 {
                guard !foundSensor else { return nil }
                foundSensor = true
                lux = number("CurrentLux", on: service)
            }
        }
        guard let lux, lux.isFinite, lux >= 0 else { return nil }
        return lux
    }

    private static func property(_ key: String, on service: io_service_t) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ key: String, on service: io_service_t) -> Double? {
        guard let value = property(key, on: service), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }
}
