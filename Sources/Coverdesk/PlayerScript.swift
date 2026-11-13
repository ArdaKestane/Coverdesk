import AppKit
import Foundation

enum PlayerKind: String {
    case music = "Music"
    case spotify = "Spotify"

    var sourceID: String {
        switch self {
        case .music: "music"
        case .spotify: "spotify"
        }
    }

    var displayName: String {
        switch self {
        case .music: "Müzik"
        case .spotify: "Spotify"
        }
    }
}

enum TransportAction {
    case play
    case pause
    case next
    case previous
    case seek(TimeInterval)

    var mediaCommand: MediaCommand {
        switch self {
        case .play: .play
        case .pause: .pause
        case .next: .nextTrack
        case .previous: .previousTrack
        case .seek: .seek
        }
    }
}

private final class AutomationNotice: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func set(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}

private final class ArtworkBox: @unchecked Sendable {
    var data: Data?
}

struct LivePlayerTiming: Sendable {
    var isPlaying: Bool
    var isStopped: Bool
    var elapsed: TimeInterval?
    var trackTitle: String
    var timestamp: Date
}

enum PlayerScript {
    private static let queue = DispatchQueue(label: "com.coverdesk.playerscript")
    /// Transport must not wait behind artwork reads. Those Apple events can take seconds.
    private static let commandQueue = DispatchQueue(label: "com.coverdesk.playercommand", qos: .userInteractive)
    /// Ultra-lightweight position & state queries (zero artwork I/O) for exact progress bar sync.
    private static let timingQueue = DispatchQueue(label: "com.coverdesk.playertiming", qos: .userInteractive)
    nonisolated(unsafe) private static var compiledTimingScripts: [PlayerKind: NSAppleScript] = [:]

    static func isRunning(_ kind: PlayerKind) -> Bool {
        let bundleID = kind == .music ? "com.apple.Music" : "com.spotify.client"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    /// Reads exact live `player state` and `player position` directly from Music or Spotify without touching artwork.
    static func liveTiming(for kind: PlayerKind) async -> LivePlayerTiming? {
        guard isRunning(kind) else { return nil }
        return await withCheckedContinuation { continuation in
            timingQueue.async {
                guard isRunning(kind) else {
                    continuation.resume(returning: nil)
                    return
                }
                let script: NSAppleScript?
                if let cached = compiledTimingScripts[kind] {
                    script = cached
                } else {
                    let source = """
                    tell application "\(kind.rawValue)"
                        if not running then return {}
                        set currentState to player state as text
                        if currentState is "stopped" then return {"stopped", -1.0, ""}
                        set trackTitle to ""
                        try
                            set trackTitle to name of current track
                        end try
                        try
                            return {currentState, (player position) as real, trackTitle}
                        on error
                            return {currentState, -1.0, trackTitle}
                        end try
                    end tell
                    """
                    let fresh = NSAppleScript(source: source)
                    var compileError: NSDictionary?
                    fresh?.compileAndReturnError(&compileError)
                    if compileError == nil, let fresh {
                        compiledTimingScripts[kind] = fresh
                    }
                    script = fresh
                }
                let startedAt = Date()
                var error: NSDictionary?
                guard let descriptor = script?.executeAndReturnError(&error),
                      error == nil,
                      descriptor.numberOfItems >= 1,
                      let state = descriptor.atIndex(1)?.stringValue?.lowercased(),
                      !state.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let finishedAt = Date()
                let replyDelay = min(0.035, max(0, finishedAt.timeIntervalSince(startedAt) * 0.3))
                let sampledAt = finishedAt.addingTimeInterval(-replyDelay)
                if state == "stopped" {
                    continuation.resume(returning: LivePlayerTiming(
                        isPlaying: false,
                        isStopped: true,
                        elapsed: nil,
                        trackTitle: "",
                        timestamp: sampledAt
                    ))
                    return
                }
                let rawPosition = doubleValue(descriptor.atIndex(2))
                let elapsed: TimeInterval? = rawPosition >= 0 ? rawPosition : nil
                let trackTitle = descriptor.atIndex(3)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: LivePlayerTiming(
                    isPlaying: state == "playing",
                    isStopped: false,
                    elapsed: elapsed,
                    trackTitle: trackTitle,
                    timestamp: sampledAt
                ))
            }
        }
    }

    private static func doubleValue(_ descriptor: NSAppleEventDescriptor?) -> Double {
        guard let descriptor else { return -1 }
        let direct = descriptor.doubleValue
        if direct != 0, direct.isFinite {
            return direct
        }
        if let text = descriptor.stringValue {
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            if let parsed = Double(normalized), parsed.isFinite {
                return parsed
            }
        }
        return direct.isFinite ? direct : -1
    }

    /// Launches Music completely hidden in the background (`hides = true, activates = false`)
    /// and waits until its player engine and startup session restoration have settled.
    static func ensureMusicRunningHidden() async -> Bool {
        if isRunning(.music) {
            for _ in 0..<16 {
                if Task.isCancelled { return isRunning(.music) }
                switch musicDaemonStatus() {
                case .ready:
                    return true
                case .denied:
                    automationNotice.fire()
                    return false
                case .starting:
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            return isRunning(.music)
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false

        let launchStartedAt = Date()
        let launched: Bool = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                app?.hide()
                continuation.resume(returning: error == nil)
            }
        }
        guard launched else { return false }
        concealMusic()

        for _ in 0..<40 {
            if Task.isCancelled { break }
            if isRunning(.music) {
                concealMusic()
                switch musicDaemonStatus() {
                case .ready:
                    // Music restores its previous saved session ~1.6-1.8s into cold launch and issues an
                    // internal Stop on that restored queue. Waiting until that window completes guarantees
                    // our upcoming queue/play command is never interrupted by startup state restoration.
                    let elapsed = Date().timeIntervalSince(launchStartedAt)
                    if elapsed < 1.85 {
                        try? await Task.sleep(for: .seconds(1.85 - elapsed))
                    }
                    concealMusic()
                    scheduleColdLaunchConcealSweep()
                    return true
                case .denied:
                    automationNotice.fire()
                    return false
                case .starting:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        concealMusic()
        scheduleColdLaunchConcealSweep()
        return isRunning(.music)
    }

    private enum DaemonStatus {
        case starting
        case ready
        case denied
    }

    private static func musicDaemonStatus() -> DaemonStatus {
        commandQueue.sync {
            let source = """
            tell application "Music"
                if not running then return ""
                try
                    set currentState to player state as text
                    set playlistCount to count of playlists
                    if playlistCount > 0 and currentState is not "" then return "ready"
                    return ""
                on error errMsg number errNum
                    if errNum is -1743 then return "denied"
                    return ""
                end try
            end tell
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?
                .executeAndReturnError(&error)
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if result == "denied" || (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 {
                return .denied
            }
            return result == "ready" ? .ready : .starting
        }
    }

    private static func scheduleColdLaunchConcealSweep() {
        Task.detached(priority: .utility) {
            for delayMS in [350, 950] {
                try? await Task.sleep(for: .milliseconds(delayMS))
                let isFront = await MainActor.run {
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Music"
                }
                if !isFront {
                    concealMusic()
                }
            }
        }
    }

    static func preferredSnapshot() async -> (snapshot: NowPlayingSnapshot?, needsAutomation: Bool) {
        let musicRunning = isRunning(.music)
        let spotifyRunning = isRunning(.spotify)
        return await withCheckedContinuation { continuation in
            queue.async {
                let music = musicRunning ? read(.music) : ReadResult()
                let spotify = spotifyRunning ? read(.spotify) : ReadResult()
                if let track = music.snapshot, track.rate > 0 {
                    continuation.resume(returning: (track, false))
                    return
                }
                if let track = spotify.snapshot, track.rate > 0 {
                    continuation.resume(returning: (track, false))
                    return
                }
                if let track = music.snapshot {
                    continuation.resume(returning: (track, false))
                    return
                }
                let needsAutomation = music.needsAutomation && spotify.snapshot == nil
                continuation.resume(returning: (spotify.snapshot, needsAutomation))
            }
        }
    }

    static func musicLyrics() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard isRunning(.music) else {
                    continuation.resume(returning: nil)
                    return
                }
                let source = """
                tell application "Music"
                    if not running then return ""
                    try
                        set lyricText to lyrics of current track
                    on error
                        set lyricText to ""
                    end try
                    return lyricText
                end tell
                """
                var error: NSDictionary?
                let text = NSAppleScript(source: source)?
                    .executeAndReturnError(&error)
                    .stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text?.isEmpty == false ? text : nil)
            }
        }
    }

    private static let automationNotice = AutomationNotice()

    static func setAutomationDeniedHandler(_ handler: @escaping @Sendable () -> Void) {
        automationNotice.set(handler)
    }

    /// Plays a track already in the user's Music library or playlists in ~0.25s without opening any window.
    @discardableResult
    static func playLibraryTrack(
        persistentID: String,
        playlistID: String? = nil,
        isPlaylistOnly: Bool = false
    ) async -> Bool {
        guard !persistentID.isEmpty, persistentID.count <= 64, persistentID.allSatisfy(\.isHexDigit) else {
            return false
        }
        let cleanPlaylistID: String? = if let playlistID, !playlistID.isEmpty, playlistID.count <= 64, playlistID.allSatisfy(\.isHexDigit) {
            playlistID
        } else {
            nil
        }

        let wasRunning = isRunning(.music)
        let wasFront = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Music"
        }
        guard await ensureMusicRunningHidden() else { return false }

        let tryLibraryFirst = isPlaylistOnly ? "" : """
            try
                play (first track of library playlist 1 whose persistent ID is "\(persistentID)")
                return "ok"
            end try
        """
        let tryKnownPlaylist = cleanPlaylistID.map { pid in
            """
            try
                set targetPl to first playlist whose persistent ID is "\(pid)"
                play (first track of targetPl whose persistent ID is "\(persistentID)")
                return "ok"
            end try
            """
        } ?? ""

        let source = """
        tell application "Music"
            if not running then return ""
            \(tryLibraryFirst)
            \(tryKnownPlaylist)
            repeat with pl in user playlists
                try
                    play (first track of pl whose persistent ID is "\(persistentID)")
                    return "ok"
                end try
            end repeat
            repeat with pl in subscription playlists
                try
                    play (first track of pl whose persistent ID is "\(persistentID)")
                    return "ok"
                end try
            end repeat
            repeat with pl in playlists
                try
                    play (first track of pl whose persistent ID is "\(persistentID)")
                    return "ok"
                end try
            end repeat
            return ""
        end tell
        """

        let maxAttempts = wasRunning ? 1 : 4
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return false }
            let played: Bool = await withCheckedContinuation { continuation in
                commandQueue.async {
                    var error: NSDictionary?
                    let result = NSAppleScript(source: source)?
                        .executeAndReturnError(&error)
                        .stringValue ?? ""
                    let number = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                    if number == -1743 {
                        automationNotice.fire()
                    }
                    if !wasRunning {
                        concealMusic()
                    } else if !wasFront {
                        concealIfUnfocused(wasFront: wasFront)
                    }
                    continuation.resume(returning: result == "ok")
                }
            }
            if played { return true }
            if attempt + 1 < maxAttempts {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        return false
    }

    /// Plays an Apple Music catalog queue (song, album, artist, or playlist) directly via MediaRemote
    /// without opening `itmss://` URLs, without Accessibility scripting, and without showing any Music window.
    @discardableResult
    static func playCatalogQueue(storeIDs: [Int]) async -> Bool {
        let validIDs = storeIDs.filter { $0 > 0 }
        guard !validIDs.isEmpty else { return false }

        let wasRunning = isRunning(.music)
        let wasFront = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Music"
        }
        guard await ensureMusicRunningHidden() else { return false }
        if !wasRunning {
            concealMusic()
        }

        // Send at most 50 tracks upfront so Music resolves the initial queue quickly without delay.
        let headIDs = Array(validIDs.prefix(50))
        var status = await MediaRemoteBridge.shared.setCatalogQueue(storeIDs: headIDs, immediatePlayback: true)
        if status == .failed {
            let maxRetries = wasRunning ? 1 : 6
            for _ in 0..<maxRetries {
                if Task.isCancelled { return false }
                if !wasRunning { concealMusic() }
                try? await Task.sleep(for: .milliseconds(300))
                status = await MediaRemoteBridge.shared.setCatalogQueue(storeIDs: headIDs, immediatePlayback: true)
                if status != .failed { break }
            }
        }
        if !wasRunning {
            concealMusic()
        } else if !wasFront {
            concealIfUnfocused(wasFront: wasFront)
        }
        guard status != .failed else { return false }

        // CRITICAL: `MRMediaRemoteSetSystemAppPlaybackQueue` with `immediatePlayback: true` only invokes its
        // completion callback (`status == 0`) AFTER `MPCPlaybackEngine` has loaded the queue, buffered the
        // stream, set `rate = 1.0`, and begun audio playback. NEVER call `setCatalogQueue` a second time once
        // accepted — doing so cancels the active queue ~1s into playback and restarts the track from 0:00!
        var didNudgePaused = false
        for check in 0..<6 {
            if Task.isCancelled { return true }
            let qState = musicQueueStatus()
            if qState == .playing { return true }
            if qState == .pausedWithTrack, check >= 2, !didNudgePaused {
                didNudgePaused = true
                send(.play, to: .music)
            }
            try? await Task.sleep(for: .milliseconds(180))
        }
        return true
    }

    private enum MusicQueueState {
        case playing
        case pausedWithTrack
        case stoppedEmpty
    }

    private static func musicQueueStatus() -> MusicQueueState {
        commandQueue.sync {
            let source = """
            tell application "Music"
                if not running then return "stopped"
                set currentState to player state as text
                if currentState is "playing" then return "playing"
                if currentState is "stopped" then return "stopped"
                try
                    set trackTitle to name of current track
                    if trackTitle is not "" then return "paused"
                end try
                return "stopped"
            end tell
            """
            var error: NSDictionary?
            let state = NSAppleScript(source: source)?
                .executeAndReturnError(&error)
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch state {
            case "playing": return .playing
            case "paused": return .pausedWithTrack
            default: return .stoppedEmpty
            }
        }
    }

    /// Launches Apple Music hidden and resumes its restored session if it matches `matchingTitle` (when provided).
    @discardableResult
    static func launchAndPerformTransport(_ action: TransportAction, matchingTitle: String? = nil) async -> Bool {
        if case .pause = action { return false }
        let wasRunning = isRunning(.music)
        guard await ensureMusicRunningHidden() else { return false }
        if !wasRunning {
            concealMusic()
        }

        let expectedTitle = (matchingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !expectedTitle.isEmpty {
            let currentRestored: String = await withCheckedContinuation { continuation in
                commandQueue.async {
                    let source = """
                    tell application "Music"
                        if not running then return ""
                        try
                            return name of current track
                        on error
                            return ""
                        end try
                    end tell
                    """
                    var error: NSDictionary?
                    let title = NSAppleScript(source: source)?
                        .executeAndReturnError(&error)
                        .stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: title)
                }
            }
            if currentRestored.isEmpty || !SearchItem.looseMatch(currentRestored, expectedTitle) {
                return false
            }
        }

        let actionScript: String = switch action {
        case .play, .pause:
            """
            if hasRestoredTrack then
                try
                    play
                end try
            end if
            """
        case .next:
            """
            if hasRestoredTrack then
                try
                    play
                    next track
                end try
            end if
            """
        case .previous:
            """
            if hasRestoredTrack then
                try
                    play
                    previous track
                end try
            end if
            """
        case .seek(let seconds):
            String(
                format: """
                if hasRestoredTrack then
                    try
                        set player position to %.3f
                        play
                    end try
                end if
                """,
                locale: Locale(identifier: "en_US_POSIX"),
                max(0, seconds)
            )
        }

        let fallbackScript = expectedTitle.isEmpty ? """
            if player state is stopped then
                try
                    play library playlist 1
                end try
            end if
            if player state is stopped then
                repeat with pl in user playlists
                    try
                        if (count of tracks of pl) > 0 then
                            play pl
                            exit repeat
                        end if
                    end try
                end repeat
            end if
        """ : ""

        let source = """
        tell application "Music"
            if not running then return ""
            set hasRestoredTrack to false
            try
                if (name of current track) is not "" then set hasRestoredTrack to true
            end try
            \(actionScript)
            \(fallbackScript)
            if player state is not stopped then return "ok"
            return ""
        end tell
        """

        let started: Bool = await withCheckedContinuation { continuation in
            commandQueue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?
                    .executeAndReturnError(&error)
                    .stringValue ?? ""
                let number = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                if number == -1743 {
                    automationNotice.fire()
                }
                if !wasRunning {
                    concealMusic()
                }
                continuation.resume(returning: result == "ok")
            }
        }
        return started
    }

    static func currentMusicArtwork() async -> Data? {
        guard isRunning(.music) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard isRunning(.music) else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = artworkFileURL(for: .music)
                let artPath = url.path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let source = """
                tell application "Music"
                    if not running then return ""
                    if player state is stopped then return ""
                    set fileRef to missing value
                    try
                        set artData to data of artwork 1 of current track
                        set fileRef to open for access (POSIX file "\(artPath)") with write permission
                        set eof of fileRef to 0
                        write artData to fileRef
                        close access fileRef
                        return "ok"
                    on error
                        try
                            if fileRef is not missing value then close access fileRef
                        end try
                        return ""
                    end try
                end tell
                """
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
                guard result == "ok", let data = try? Data(contentsOf: url), data.count > 32 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Appends remaining album/artist/playlist Store IDs to Apple Music's Up Next queue in the background.
    static func enqueueUpNext(storeIDs: [Int]) async {
        let validIDs = storeIDs.filter { $0 > 0 }
        guard !validIDs.isEmpty else { return }
        _ = await MediaRemoteBridge.shared.insertCatalogQueue(storeIDs: validIDs, position: 1)
    }

    private static func concealIfUnfocused(wasFront: Bool) {
        guard !wasFront else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music") where app.isActive {
            app.hide()
        }
    }

    private static func concealMusic() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music") where !app.isHidden {
            app.hide()
        }
    }

    static func send(_ action: TransportAction, to kind: PlayerKind) {
        if kind == .music, !isRunning(.music) {
            if case .pause = action { return }
            Task {
                _ = await launchAndPerformTransport(action)
            }
            return
        }
        let source = transportScript(action, kind: kind)
        commandQueue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let number = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            guard number == -1743 else { return }
            let position: Double? = if case .seek(let seconds) = action { seconds } else { nil }
            MediaRemoteBridge.shared.send(action.mediaCommand, position: position)
        }
    }

    private static func transportScript(_ action: TransportAction, kind: PlayerKind) -> String {
        let application = kind.rawValue
        let command: String
        switch action {
        case .play:
            command = "play"
        case .pause:
            command = "pause"
        case .next:
            command = "next track"
        case .previous:
            command = "previous track"
        case .seek(let seconds):
            let position = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            command = "set player position to \(position)"
        }
        return """
        if application "\(application)" is running then
            tell application "\(application)" to \(command)
        end if
        """
    }

    private struct ReadResult {
        var snapshot: NowPlayingSnapshot?
        var needsAutomation = false
    }

    private static func read(_ kind: PlayerKind) -> ReadResult {
        let artPath = artworkFileURL(for: kind).path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: script(for: kind, artworkPath: artPath))?
            .executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if number == -1743 {
                return ReadResult(needsAutomation: true)
            }
            return ReadResult()
        }
        guard let text = descriptor?.stringValue, !text.isEmpty else { return ReadResult() }
        return ReadResult(snapshot: parse(text, kind: kind))
    }

    private static func parse(_ text: String, kind: PlayerKind) -> NowPlayingSnapshot? {
        let sampledAt = Date()
        let parts = text.components(separatedBy: "\t")
        guard parts.count >= 6 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = (Double(parts[3]) ?? 0) / 1000
        let elapsed = (Double(parts[4]) ?? 0) / 1000
        let rate = parts[5] == "1" ? 1.0 : 0
        let artwork = artworkData(kind: kind, field: parts.count > 6 ? parts[6] : "")
        return NowPlayingSnapshot(
            title: title,
            artist: artist,
            album: album,
            isMusicApp: kind == .music,
            sourceName: kind.displayName,
            artwork: artwork,
            artworkIdentifier: "\(kind.sourceID):\(album):\(title)",
            duration: duration,
            elapsed: elapsed,
            rate: rate,
            timestamp: sampledAt,
            inTransition: false,
            source: kind.sourceID
        )
    }

    private static func artworkData(kind: PlayerKind, field: String) -> Data? {
        switch kind {
        case .music:
            guard !field.isEmpty else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: field))
        case .spotify:
            guard let url = URL(string: field), url.scheme == "https" else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let box = ArtworkBox()
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    box.data = data
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 9)
            return box.data
        }
    }

    private static func artworkFileURL(for kind: PlayerKind) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coverdesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(kind.sourceID)-artwork.bin")
    }

    private static func script(for kind: PlayerKind, artworkPath: String) -> String {
        switch kind {
        case .music:
            """
            tell application "Music"
                if not running then return ""
                if player state is stopped then return ""
                set t to current track
                set dur to 0
                try
                    set dur to (round ((duration of t) * 1000) rounding down) as integer
                end try
                set artPath to ""
                set fileRef to missing value
                try
                    set artData to data of artwork 1 of t
                    set artPath to "\(artworkPath)"
                    set fileRef to open for access (POSIX file artPath) with write permission
                    set eof of fileRef to 0
                    write artData to fileRef
                end try
                try
                    if fileRef is not missing value then close access fileRef
                end try
                set isPlaying to "0"
                if player state is playing then set isPlaying to "1"
                set pos to 0
                try
                    set pos to (round ((player position) * 1000) rounding down) as integer
                end try
                set AppleScript's text item delimiters to tab
                return (name of t) & tab & (artist of t) & tab & (album of t) & tab & (dur as text) & tab & (pos as text) & tab & isPlaying & tab & artPath
            end tell
            """
        case .spotify:
            """
            tell application "Spotify"
                if not running then return ""
                if player state is stopped then return ""
                set isPlaying to "0"
                if player state is playing then set isPlaying to "1"
                set dur to (duration of current track) as integer
                set pos to 0
                try
                    set pos to (round ((player position) * 1000) rounding down) as integer
                end try
                set artURL to ""
                try
                    set artURL to artwork url of current track
                end try
                set AppleScript's text item delimiters to tab
                return (name of current track) & tab & (artist of current track) & tab & (album of current track) & tab & (dur as text) & tab & (pos as text) & tab & isPlaying & tab & artURL
            end tell
            """
        }
    }
}
