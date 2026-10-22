import AppKit
import DiskArbitration

enum DriveKind: Equatable, Sendable {
    case usb, sdCard, optical, external, diskImage

    /// For the notch alert; the page shows Finder's own icon for the volume.
    var symbol: String {
        let preferred = switch self {
        case .usb: "mediastick"
        case .sdCard: "sdcard.fill"
        case .optical: "opticaldisc.fill"
        case .external, .diskImage: "externaldrive.fill"
        }
        // Newer symbols are missing on older macOS.
        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : "externaldrive.fill"
    }
}

/// A mounted volume the user can unplug.
struct Drive: Identifiable, Equatable, Sendable {
    let url: URL
    var name: String
    var kind: DriveKind
    var total: Int64?
    var free: Int64?

    /// The mount point; stable for as long as the volume is mounted.
    var id: String { url.path }

    /// 0…1, nil until the capacity is known.
    var freeFraction: Double? {
        guard let total, let free, total > 0 else { return nil }
        return min(max(Double(free) / Double(total), 0), 1)
    }
}

/// Decides which volumes count as drives, from what DiskArbitration says
/// about the device behind them. `volumeIsRemovableKey` alone isn't enough:
/// disk images claim to be removable, and some USB enclosures claim not to be.
enum DriveClassifier {
    static func kind(of description: [String: Any], includeDiskImages: Bool) -> DriveKind? {
        func string(_ key: CFString) -> String? { description[key as String] as? String }
        func flag(_ key: CFString) -> Bool? { description[key as String] as? Bool }

        let deviceProtocol = string(kDADiskDescriptionDeviceProtocolKey)
        let model = string(kDADiskDescriptionDeviceModelKey)
        if deviceProtocol == "Virtual Interface" || model == "Disk Image" {
            return includeDiskImages ? .diskImage : nil
        }
        // Volumes without a device (network shares, synthesized ones) report no
        // internal flag; treat them as internal.
        let isInternal = flag(kDADiskDescriptionDeviceInternalKey) ?? true
        let isRemovable = flag(kDADiskDescriptionMediaRemovableKey) ?? false
        let isEjectable = flag(kDADiskDescriptionMediaEjectableKey) ?? false
        // A built-in SD card slot is internal, but its card is removable.
        guard !isInternal || isRemovable || isEjectable else { return nil }

        let mediaKind = string(kDADiskDescriptionMediaKindKey) ?? ""
        if ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(mediaKind) { return .optical }
        if deviceProtocol == "Secure Digital" || (model ?? "").range(of: #"\bSD(HC|XC)?\b"#, options: .regularExpression) != nil {
            return .sdCard
        }
        if deviceProtocol == "USB" { return .usb }
        return .external
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
    ]

    /// The drive mounted at `url`, or nil when it isn't one. Talks to the file
    /// system and diskarbitrationd, which can stall on a failing disk, so
    /// never call it on the main thread.
    static func drive(at url: URL, includeDiskImages: Bool) -> Drive? {
        var url = url
        url.removeAllCachedResourceValues()
        // A drive pulled out without ejecting can stay mounted but unreadable; skip it.
        guard let values = try? url.resourceValues(forKeys: resourceKeys),
              values.volumeIsLocal == true, values.volumeIsBrowsable != false,
              values.volumeIsRootFileSystem != true,
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let kind = kind(of: description, includeDiskImages: includeDiskImages) else { return nil }

        // The "important usage" figure counts purgeable space, like Finder; some
        // file systems only report the plain one.
        let important = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        return Drive(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent, kind: kind,
                     total: values.volumeTotalCapacity.map(Int64.init),
                     free: important ?? values.volumeAvailableCapacity.map(Int64.init))
    }
}

enum DriveFormat {
    /// "64 GB", "1.2 TB", "940 MB": decimal units, like Finder.
    static func bytes(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value < 10 && unit > 0 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(units[unit])"
    }
}
