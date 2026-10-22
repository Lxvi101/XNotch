import DiskArbitration
import XCTest
@testable import Drives

final class DrivesTests: XCTestCase {
    private func description(protocol deviceProtocol: String? = nil, model: String? = nil, isInternal: Bool? = nil,
                             removable: Bool = false, ejectable: Bool = false,
                             mediaKind: String = "IOMedia") -> [String: Any] {
        var description: [String: Any] = [
            kDADiskDescriptionMediaRemovableKey as String: removable,
            kDADiskDescriptionMediaEjectableKey as String: ejectable,
            kDADiskDescriptionMediaKindKey as String: mediaKind
        ]
        description[kDADiskDescriptionDeviceProtocolKey as String] = deviceProtocol
        description[kDADiskDescriptionDeviceModelKey as String] = model
        description[kDADiskDescriptionDeviceInternalKey as String] = isInternal
        return description
    }

    func testInternalDiskIsNotADrive() {
        let ssd = description(protocol: "Apple Fabric", model: "APPLE SSD AP0512Z", isInternal: true)
        XCTAssertNil(DriveClassifier.kind(of: ssd, includeDiskImages: true))
    }

    func testVolumeWithoutDeviceIsNotADrive() {
        XCTAssertNil(DriveClassifier.kind(of: [:], includeDiskImages: true))
    }

    func testDiskImagesOnlyWhenAsked() {
        // Disk images claim to be removable and ejectable.
        let image = description(protocol: "Virtual Interface", model: "Disk Image", removable: true, ejectable: true)
        XCTAssertNil(DriveClassifier.kind(of: image, includeDiskImages: false))
        XCTAssertEqual(DriveClassifier.kind(of: image, includeDiskImages: true), .diskImage)
    }

    func testExternalDrivesByProtocol() {
        XCTAssertEqual(DriveClassifier.kind(of: description(protocol: "USB", isInternal: false), includeDiskImages: false), .usb)
        // Some USB enclosures say they're fixed media; they're still external.
        XCTAssertEqual(DriveClassifier.kind(of: description(protocol: "Thunderbolt", isInternal: false, removable: false),
                                            includeDiskImages: false), .external)
    }

    func testBuiltInCardReader() {
        let card = description(protocol: "Secure Digital", model: "SDXC Reader", isInternal: true, removable: true, ejectable: true)
        XCTAssertEqual(DriveClassifier.kind(of: card, includeDiskImages: false), .sdCard)
        let usbReader = description(protocol: "USB", model: "SD Card Reader", isInternal: false, removable: true)
        XCTAssertEqual(DriveClassifier.kind(of: usbReader, includeDiskImages: false), .sdCard)
    }

    func testOpticalMedia() {
        let dvd = description(protocol: "USB", isInternal: false, removable: true, mediaKind: "IODVDMedia")
        XCTAssertEqual(DriveClassifier.kind(of: dvd, includeDiskImages: false), .optical)
    }

    func testSettingsRoundTripAndDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "drives.tests.\(UUID())"))
        XCTAssertEqual(DrivesSettings.load(from: defaults), DrivesSettings())
        let settings = DrivesSettings(alertsOnConnect: false, alertsOnEject: true, includesDiskImages: true)
        settings.save(to: defaults)
        XCTAssertEqual(DrivesSettings.load(from: defaults), settings)
    }

    func testByteFormatUsesDecimalUnits() {
        XCTAssertTrue(DriveFormat.bytes(64_000_000_000).hasSuffix(" GB"))
        XCTAssertTrue(DriveFormat.bytes(940_000_000).hasPrefix("940"))
        XCTAssertTrue(DriveFormat.bytes(1_200_000_000_000).hasSuffix(" TB"))
    }
}
