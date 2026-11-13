import AppKit
import Foundation

struct RenderedWallpaper: Sendable {
    var displayID: UInt32
    var filePath: String
}

struct WallpaperUpdate: Sendable {
    var error: String?
    var didChange: Bool
}

@MainActor
final class WallpaperController {
    private let fileManager = FileManager.default
    private var appliedKey: String?
    private var activeFiles: [UInt32: URL] = [:]

    var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Coverdesk", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func rememberOriginals() {
        var stored = loadOriginals()
        var changed = false
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            if let existing = stored[displayID],
               fileManager.fileExists(atPath: existing.path),
               isOwnedOriginal(existing.path) {
                continue
            }
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !isCoverdeskWallpaper(url),
                  fileManager.fileExists(atPath: url.path)
            else { continue }
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let copy = directory.appendingPathComponent("original-\(displayID).\(ext)")
            do {
                if fileManager.fileExists(atPath: copy.path) {
                    try fileManager.removeItem(at: copy)
                }
                try fileManager.copyItem(at: url, to: copy)
            } catch {
                continue
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let optionsData = try? NSKeyedArchiver.archivedData(
                withRootObject: options as NSDictionary,
                requiringSecureCoding: false
            )
            stored[displayID] = StoredDesktop(path: copy.path, optionsData: optionsData)
            changed = true
        }
        if changed {
            saveOriginals(stored)
        }
    }

    func setWallpapers(_ files: [RenderedWallpaper], key: String) -> WallpaperUpdate {
        if key == appliedKey {
            return WallpaperUpdate(error: nil, didChange: false)
        }
        var errors: [String] = []
        var written: [UInt32: URL] = [:]
        for file in files {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == file.displayID }) else { continue }
            let url = URL(fileURLWithPath: file.filePath)
            do {
                try assign(url, to: screen)
                written[file.displayID] = url
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        guard !written.isEmpty else {
            return WallpaperUpdate(
                error: errors.first ?? "Duvar kağıdı uygulanamadı.",
                didChange: false
            )
        }
        let previous = activeFiles
        activeFiles = written
        appliedKey = key
        for (_, url) in previous where !written.values.contains(url) {
            try? fileManager.removeItem(at: url)
        }
        cleanupStrays(keeping: Set(written.values.map(\.path)))
        return WallpaperUpdate(error: errors.first, didChange: true)
    }

    func restoreOriginals() {
        let stored = loadOriginals()
        for screen in NSScreen.screens {
            guard let record = stored[screen.displayID] else { continue }
            let url = URL(fileURLWithPath: record.path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let options = unarchiveOptions(record.optionsData) ?? Self.defaultOptions
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
        appliedKey = nil
    }

    func invalidate() {
        appliedKey = nil
    }

    private func cleanupStrays(keeping: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("wallpaper-") && !keeping.contains(file.path) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func isCoverdeskWallpaper(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("wallpaper-") && url.path.contains("/Coverdesk/")
    }

    private func isOwnedOriginal(_ path: String) -> Bool {
        path.contains("/Coverdesk/original-")
    }

    private func assign(_ url: URL, to screen: NSScreen) throws {
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.defaultOptions)
        } catch {
            try NSWorkspace.shared.setDesktopImageURL(
                url,
                for: screen,
                options: [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                    .allowClipping: NSNumber(value: false),
                ]
            )
        }
    }

    private static let defaultOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
        .allowClipping: NSNumber(value: false),
        .fillColor: NSColor.black,
    ]

    private struct StoredDesktop: Codable {
        var path: String
        var optionsData: Data?
    }

    private func originalsURL() -> URL {
        directory.appendingPathComponent("originals.json")
    }

    private func loadOriginals() -> [UInt32: StoredDesktop] {
        let url = originalsURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: StoredDesktop].self, from: data)
        else { return [:] }
        var result: [UInt32: StoredDesktop] = [:]
        for (key, value) in decoded {
            if let id = UInt32(key) {
                result[id] = value
            }
        }
        return result
    }

    private func saveOriginals(_ originals: [UInt32: StoredDesktop]) {
        var encoded: [String: StoredDesktop] = [:]
        for (key, value) in originals {
            encoded[String(key)] = value
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: originalsURL(), options: .atomic)
    }

    private func unarchiveOptions(_ data: Data?) -> [NSWorkspace.DesktopImageOptionKey: Any]? {
        guard let data,
              let object = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self, NSURL.self],
                  from: data
              )
        else { return nil }
        if let typed = object as? [NSWorkspace.DesktopImageOptionKey: Any] {
            return typed
        }
        guard let dictionary = object as? NSDictionary else { return nil }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        for (key, value) in dictionary {
            if let key = key as? String {
                options[NSWorkspace.DesktopImageOptionKey(rawValue: key)] = value
            }
        }
        return options
    }
}
