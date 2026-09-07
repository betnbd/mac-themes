import AppKit
import CoreGraphics
import ThemeCore

struct WallpaperDesktopSnapshot {
    let id: String
    let legacyID: String
    let image: URL
    let options: Data
}

@MainActor protocol WallpaperDesktopClient {
    func snapshots() throws -> [WallpaperDesktopSnapshot]
    func setImage(_ url: URL, on displayID: String, restoringOptions: Data?) throws
}

@MainActor struct NativeWallpaperDesktopClient: WallpaperDesktopClient {
    private func identity(_ screen: NSScreen) throws -> (String, String) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            throw ThemeError.message("Could not identify display \(screen.localizedName) for a restorable wallpaper change.")
        }
        return ("display:" + (CFUUIDCreateString(nil, uuid) as String), String(number.uint32Value))
    }

    func snapshots() throws -> [WallpaperDesktopSnapshot] {
        try NSScreen.screens.map { screen in
            let (id, legacy) = try identity(screen)
            guard let image = NSWorkspace.shared.desktopImageURL(for: screen) else {
                throw ThemeError.message("Could not capture the current wallpaper for \(screen.localizedName).")
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let archived = try NSKeyedArchiver.archivedData(withRootObject: Dictionary(uniqueKeysWithValues: options.map { ($0.key.rawValue, $0.value) }), requiringSecureCoding: true)
            return WallpaperDesktopSnapshot(id: id, legacyID: legacy, image: image, options: archived)
        }
    }

    func setImage(_ url: URL, on displayID: String, restoringOptions data: Data?) throws {
        guard let screen = NSScreen.screens.first(where: { (try? identity($0).0) == displayID }) else {
            throw ThemeError.message("The display disconnected before its wallpaper could be changed.")
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
        if let data {
            let allowed: [AnyClass] = [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self, NSColorSpace.self, NSData.self]
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClasses: allowed, from: data) as? [String: Any] else {
                throw ThemeError.message("Wallpaper options backup is invalid; restoration stopped.")
            }
            options = Dictionary(uniqueKeysWithValues: decoded.map { (NSWorkspace.DesktopImageOptionKey(rawValue: $0.key), $0.value) })
        } else { options = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true] }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }
}
