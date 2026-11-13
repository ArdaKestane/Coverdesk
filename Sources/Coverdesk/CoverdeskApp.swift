import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: ControlPanelController?
    private var fade: DesktopFadeController?
    private var lyrics: LyricsOverlayController?
    private var keyMonitor: Any?
    private var lastNudge = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableSuddenTermination()
        let fade = DesktopFadeController()
        let lyrics = LyricsOverlayController(model: model)
        self.fade = fade
        self.lyrics = lyrics
        panel = ControlPanelController(model: model)
        let controlsChanged = model.onInterfaceChange
        let playbackChanged = model.onPlaybackChange
        model.onInterfaceChange = { [weak self] in
            controlsChanged?()
            self?.lyrics?.apply()
        }
        model.onPlaybackChange = { [weak self] in
            playbackChanged?()
            self?.lyrics?.refresh()
        }
        model.onWallpaperReady = { [weak fade] files in
            fade?.crossfade(files)
        }
        model.start()
        panel?.show()
        lyrics.apply()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showFromLaunch),
            name: .coverdeskShow,
            object: nil
        )
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let isRepeat = event.isARepeat
            let consumed = MainActor.assumeIsolated {
                self?.consumeKey(keyCode: keyCode, flags: flags, isRepeat: isRepeat) ?? false
            }
            return consumed ? nil : event
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.coverdesk.app"
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
        guard alreadyRunning else { return }
        DistributedNotificationCenter.default().post(name: .coverdeskShow, object: nil)
        exit(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// MenuBarExtra's status item asks the app to quit as soon as Raycast or Launch Services opens it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let fromStatusItem = Thread.callStackSymbols.contains { $0.contains("NSSceneStatusItem") }
        return fromStatusItem ? .terminateCancel : .terminateNow
    }

    @objc private func showFromLaunch(_ notification: Notification) {
        panel?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        fade?.hide()
        lyrics?.hide()
        model.prepareForQuit()
    }

    private func consumeKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard NSApp.isActive else { return false }
        let keyWindow = NSApp.keyWindow
        let focused = panel?.owns(keyWindow) == true || lyrics?.owns(keyWindow) == true
        if flags.contains(.command), !isRepeat,
           flags.intersection([.shift, .option, .control]).isEmpty,
           keyWindow == nil || focused {
            if keyCode == 3 {
                model.presentSearch()
                return true
            }
            if keyCode == 37 {
                model.togglePlaylists()
                return true
            }
        }
        guard focused else { return false }
        if model.isOverlayPresented, panel?.owns(keyWindow) == true {
            if keyCode == 53, !isRepeat {
                model.cancelOverlay()
                return true
            }
            if keyCode == 36, !isRepeat, flags.contains(.command) {
                model.submitOverlaySelection(direct: true)
                return true
            }
            let editingText = model.isSearchPresented && (keyWindow?.firstResponder is NSTextView)
            if !editingText {
                switch keyCode {
                case 49 where !isRepeat && flags.intersection([.command, .option, .control]).isEmpty:
                    model.playPause()
                    return true
                case 126:
                    model.moveOverlaySelection(by: -1)
                    return true
                case 125:
                    model.moveOverlaySelection(by: 1)
                    return true
                case 36 where !isRepeat:
                    model.submitOverlaySelection(direct: false)
                    return true
                case 48 where !isRepeat && model.isSearchPresented && model.searchStack.isEmpty:
                    model.toggleSearchScope()
                    return true
                default:
                    break
                }
            }
            return false
        }
        let blocked: NSEvent.ModifierFlags = [.command, .option, .control]
        if !flags.intersection(blocked).isEmpty { return false }
        if keyCode == 49, !isRepeat {
            model.playPause()
            return true
        }
        let delta: TimeInterval?
        switch keyCode {
        case 123: delta = -5
        case 124: delta = 5
        default: delta = nil
        }
        guard let delta else { return false }
        if isRepeat, Date().timeIntervalSince(lastNudge) < 0.18 {
            return true
        }
        lastNudge = .now
        model.nudge(by: delta)
        return true
    }
}

@main
struct CoverdeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appDelegate.model)
        } label: {
            Image(systemName: "music.note")
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

private struct MenuBarView: View {
    var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.title.isEmpty ? "Çalan bir şey yok" : model.title)
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.sourceName.isEmpty {
                Text(model.sourceName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        Divider()
        Button("Çalma Listeleri…") {
            model.presentPlaylists()
        }
        .keyboardShortcut("l", modifiers: .command)
        Button("Şarkı Ara…") {
            model.presentSearch()
        }
        .keyboardShortcut("f", modifiers: .command)
        Divider()
        Toggle("Kontrolleri Göster", isOn: Binding(
            get: { model.preferences.controlsVisible },
            set: { model.preferences.controlsVisible = $0 }
        ))
        Toggle("Sözleri Göster", isOn: Binding(
            get: { model.preferences.lyricsVisible },
            set: { model.preferences.lyricsVisible = $0 }
        ))
        Picker("Görünüm", selection: Binding(
            get: { model.preferences.style },
            set: { model.preferences.style = $0 }
        )) {
            ForEach(WallpaperStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        Divider()
        Button("Kapağı Yeniden Uygula") {
            model.reapplyArtwork()
        }
        Button("Özgün Duvar Kağıdını Geri Yükle") {
            model.restoreOriginalWallpaper()
        }
        Button("Çubuğu Alta Hizala") {
            model.preferences.clearCustomOrigin()
        }
        Divider()
        Button("Ayarlar…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Coverdesk’ten Çık") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private extension Notification.Name {
    static let coverdeskShow = Notification.Name("com.coverdesk.show")
}
