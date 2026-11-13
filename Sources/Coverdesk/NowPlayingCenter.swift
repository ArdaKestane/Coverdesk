import AppKit
import Darwin
import Foundation

struct PlaybackClock: Equatable {
    var anchorElapsed: TimeInterval = 0
    var anchorDate: Date = .now
    var rate: Double = 0
    var duration: TimeInterval = 0

    func elapsed(at date: Date) -> TimeInterval {
        let value = anchorElapsed + date.timeIntervalSince(anchorDate) * max(0, rate)
        if duration > 1 {
            return min(max(0, value), duration)
        }
        return max(0, value)
    }

    var isPlaying: Bool { rate > 0.05 }
}

struct NowPlayingSnapshot: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var isMusicApp: Bool
    var sourceName: String?
    var artwork: Data?
    var artworkIdentifier: String?
    var duration: TimeInterval
    var elapsed: TimeInterval
    var rate: Double
    var infoRate: Double
    var timestamp: Date
    var inTransition: Bool
    var source: String = "system"
    var storeID: Int?
    var albumStoreID: Int?
    var artistStoreID: Int?

    init(
        title: String,
        artist: String,
        album: String,
        isMusicApp: Bool,
        sourceName: String?,
        artwork: Data?,
        artworkIdentifier: String?,
        duration: TimeInterval,
        elapsed: TimeInterval,
        rate: Double,
        infoRate: Double? = nil,
        timestamp: Date,
        inTransition: Bool,
        source: String = "system",
        storeID: Int? = nil,
        albumStoreID: Int? = nil,
        artistStoreID: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isMusicApp = isMusicApp
        self.sourceName = sourceName
        self.artwork = artwork
        self.artworkIdentifier = artworkIdentifier
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.infoRate = infoRate ?? rate
        self.timestamp = timestamp
        self.inTransition = inTransition
        self.source = source
        self.storeID = storeID
        self.albumStoreID = albumStoreID
        self.artistStoreID = artistStoreID
    }

    var hasDisplayableArtwork: Bool {
        if let artwork, !artwork.isEmpty { return true }
        return false
    }

    var trackID: String {
        [title, artist, album].joined(separator: "\u{1f}")
    }

    var artworkToken: String {
        let identity = artworkIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "embedded"
        return "\(identity)#\(artwork?.count ?? 0)"
    }

    func clock(at date: Date = .now) -> PlaybackClock {
        let elapsedSinceAnchor = max(0, date.timeIntervalSince(timestamp))
        let drifted = elapsed + elapsedSinceAnchor * max(0, infoRate)
        let clamped = duration > 1 ? min(max(0, drifted), duration) : max(0, drifted)
        return PlaybackClock(
            anchorElapsed: clamped,
            anchorDate: date,
            rate: rate,
            duration: duration
        )
    }
}

struct ImmediatePlaybackHint: Sendable {
    var source: String?
    var isPlaying: Bool?
    var isStopped: Bool = false
    var elapsed: TimeInterval?
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
}

enum MediaCommand: UInt32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
    case seek = 14
}

enum CatalogQueueStatus: Equatable, Sendable {
    case succeeded
    case failed
    case timedOut
}

/// Reads the system Now Playing session (Apple Music, Spotify, Chrome, and the rest)
/// through the private MediaRemote framework that macOS itself uses.
final class MediaRemoteBridge: @unchecked Sendable {
    static let shared = MediaRemoteBridge()

    private let callbackQueue = DispatchQueue(label: "com.coverdesk.mediaremote")
    private let getInfo: GetInfoFn?
    private let getIsPlaying: GetIsPlayingFn?
    private let getPID: GetPIDFn?
    private let register: RegisterFn?
    private let sendCommand: SendFn?
    private let createQueue: CreateQueueFn?
    private let destroyQueue: DestroyQueueFn?
    private let setTracklistStoreIDs: SetTracklistStoreIDsFn?
    private let setImmediatePlayback: SetImmediatePlaybackFn?
    private let setShuffleMode: SetIntOptionFn?
    private let setSystemQueue: SetSystemQueueFn?
    private let insertSystemQueue: InsertSystemQueueFn?

    var isAvailable: Bool { getInfo != nil && sendCommand != nil }
    var canQueueCatalog: Bool {
        createQueue != nil && destroyQueue != nil && setTracklistStoreIDs != nil && setSystemQueue != nil
    }

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias CreateQueueFn = @convention(c) (CFAllocator?, Int32) -> UnsafeMutableRawPointer?
    private typealias DestroyQueueFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias SetTracklistStoreIDsFn = @convention(c) (UnsafeMutableRawPointer, CFArray) -> Void
    private typealias SetImmediatePlaybackFn = @convention(c) (UnsafeMutableRawPointer, Bool) -> Void
    private typealias SetIntOptionFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias SetSystemQueueFn = @convention(c) (
        UnsafeMutableRawPointer,
        DispatchQueue?,
        (@convention(block) (UInt32) -> Void)?
    ) -> Void
    private typealias InsertSystemQueueFn = @convention(c) (
        UnsafeMutableRawPointer,
        Int32,
        UnsafeRawPointer?,
        DispatchQueue?,
        (@convention(block) (UInt32) -> Void)?
    ) -> Void

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        getInfo = handle.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }.map {
            unsafeBitCast($0, to: GetInfoFn.self)
        }
        getIsPlaying = handle.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") }.map {
            unsafeBitCast($0, to: GetIsPlayingFn.self)
        }
        getPID = handle.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingApplicationPID") }.map {
            unsafeBitCast($0, to: GetPIDFn.self)
        }
        register = handle.flatMap { dlsym($0, "MRMediaRemoteRegisterForNowPlayingNotifications") }.map {
            unsafeBitCast($0, to: RegisterFn.self)
        }
        sendCommand = handle.flatMap { dlsym($0, "MRMediaRemoteSendCommand") }.map {
            unsafeBitCast($0, to: SendFn.self)
        }
        createQueue = handle.flatMap { dlsym($0, "MRSystemAppPlaybackQueueCreate") }.map {
            unsafeBitCast($0, to: CreateQueueFn.self)
        }
        destroyQueue = handle.flatMap { dlsym($0, "MRSystemAppPlaybackQueueDestroy") }.map {
            unsafeBitCast($0, to: DestroyQueueFn.self)
        }
        setTracklistStoreIDs = handle.flatMap { dlsym($0, "MRSystemAppPlaybackQueueSetTracklistStoreIDs") }.map {
            unsafeBitCast($0, to: SetTracklistStoreIDsFn.self)
        }
        setImmediatePlayback = handle.flatMap { dlsym($0, "MRSystemAppPlaybackQueueSetIsRequestingImmediatePlayback") }.map {
            unsafeBitCast($0, to: SetImmediatePlaybackFn.self)
        }
        setShuffleMode = handle.flatMap { dlsym($0, "MRSystemAppPlaybackQueueSetTracklistShuffleMode") }.map {
            unsafeBitCast($0, to: SetIntOptionFn.self)
        }
        setSystemQueue = handle.flatMap { dlsym($0, "MRMediaRemoteSetSystemAppPlaybackQueue") }.map {
            unsafeBitCast($0, to: SetSystemQueueFn.self)
        }
        insertSystemQueue = handle.flatMap { dlsym($0, "MRMediaRemoteInsertSystemAppPlaybackQueue") }.map {
            unsafeBitCast($0, to: InsertSystemQueueFn.self)
        }
    }

    func registerForNotifications() {
        register?(DispatchQueue.main)
    }

    func isPlaying() async -> Bool? {
        guard let getIsPlaying else { return nil }
        let queue = callbackQueue
        return await withCheckedContinuation { continuation in
            getIsPlaying(queue) { playing in
                continuation.resume(returning: playing)
            }
        }
    }

    func snapshot() async -> NowPlayingSnapshot? {
        guard let getInfo else { return nil }
        let queue = callbackQueue
        var snapshot: NowPlayingSnapshot = await withCheckedContinuation { continuation in
            getInfo(queue) { info in
                continuation.resume(returning: NowPlayingSnapshot.parse(info, sourceName: nil))
            }
        }
        async let livePlayingTask = isPlaying()
        async let appTask = currentApplication()
        let livePlaying = await livePlayingTask
        let application = await appTask
        if snapshot.isMusicApp || application.bundleID == "com.apple.Music" {
            snapshot.isMusicApp = true
            snapshot.sourceName = "Müzik"
            snapshot.source = PlayerKind.music.sourceID
        } else if application.bundleID == "com.spotify.client" {
            snapshot.sourceName = application.name ?? PlayerKind.spotify.displayName
            snapshot.source = PlayerKind.spotify.sourceID
        } else {
            snapshot.sourceName = application.name
            snapshot.source = "system"
        }
        if let livePlaying, !snapshot.title.isEmpty {
            snapshot.rate = livePlaying ? (snapshot.infoRate > 0.05 ? snapshot.infoRate : 1.0) : 0.0
        }
        return snapshot
    }

    func send(_ command: MediaCommand, position: Double? = nil) {
        guard let sendCommand else { return }
        if let position {
            let options = ["kMRMediaRemoteOptionPlaybackPosition": position] as CFDictionary
            _ = sendCommand(command.rawValue, options)
        } else {
            _ = sendCommand(command.rawValue, nil)
        }
    }

    func activeBundleIdentifier() async -> String? {
        await currentApplication().bundleID
    }

    /// Replaces Apple Music's playback queue with Store IDs directly via MediaRemote IPC (no windows opened).
    func setCatalogQueue(storeIDs: [Int], immediatePlayback: Bool = true) async -> CatalogQueueStatus {
        let ids = Self.normalizedStoreIDs(storeIDs, limit: 60)
        guard !ids.isEmpty,
              let createQueue,
              let destroyQueue,
              let setTracklistStoreIDs,
              let setSystemQueue
        else { return .failed }

        let gate = OnceFlag()
        return await withCheckedContinuation { continuation in
            guard let queue = createQueue(kCFAllocatorDefault, 3) else {
                continuation.resume(returning: .failed)
                return
            }
            setTracklistStoreIDs(queue, ids as CFArray)
            setImmediatePlayback?(queue, immediatePlayback)
            setShuffleMode?(queue, 1) // 1 = Off (keep exact track order)

            setSystemQueue(queue, callbackQueue) { status in
                if gate.claim() {
                    continuation.resume(returning: status == 0 ? .succeeded : .failed)
                }
            }
            destroyQueue(queue)

            callbackQueue.asyncAfter(deadline: .now() + 15) {
                if gate.claim() {
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    /// Appends Store IDs into Apple Music's Up Next queue without interrupting the currently playing track.
    func insertCatalogQueue(storeIDs: [Int], position: Int32 = 1) async -> Bool {
        let ids = Self.normalizedStoreIDs(storeIDs, limit: 120)
        guard !ids.isEmpty,
              let createQueue,
              let destroyQueue,
              let setTracklistStoreIDs,
              let insertSystemQueue
        else { return false }

        let gate = OnceFlag()
        return await withCheckedContinuation { continuation in
            guard let queue = createQueue(kCFAllocatorDefault, 3) else {
                continuation.resume(returning: false)
                return
            }
            setTracklistStoreIDs(queue, ids as CFArray)
            setImmediatePlayback?(queue, false)

            insertSystemQueue(queue, position, nil, callbackQueue) { status in
                if gate.claim() {
                    continuation.resume(returning: status == 0)
                }
            }
            destroyQueue(queue)

            callbackQueue.asyncAfter(deadline: .now() + 10) {
                if gate.claim() {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func normalizedStoreIDs(_ raw: [Int], limit: Int) -> [String] {
        var result: [String] = []
        result.reserveCapacity(min(raw.count, limit))
        for id in raw where id > 0 {
            let text = String(id)
            if result.last != text {
                result.append(text)
            }
            if result.count >= limit { break }
        }
        return result
    }

    private func currentApplication() async -> (name: String?, bundleID: String?) {
        guard let getPID else { return (nil, nil) }
        let queue = callbackQueue
        let pid: Int32 = await withCheckedContinuation { continuation in
            getPID(queue) { pid in
                continuation.resume(returning: pid)
            }
        }
        guard pid > 0, let application = NSRunningApplication(processIdentifier: pid) else {
            return (nil, nil)
        }
        return (application.localizedName, application.bundleIdentifier)
    }
}

@MainActor
final class NowPlayingCenter {
    private let bridge = MediaRemoteBridge.shared
    private var tokens: [NSObjectProtocol] = []
    private var onChange: (@Sendable () -> Void)?

    var isAvailable: Bool { bridge.isAvailable }

    func start(
        onImmediateHint: @escaping @Sendable (ImmediatePlaybackHint) -> Void = { _ in },
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        bridge.registerForNotifications()
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "com.apple.Music.playerInfo",
            "com.spotify.client.PlaybackStateChanged",
        ]
        let center = DistributedNotificationCenter.default()
        let handleChange = onChange
        let handleHint = onImmediateHint
        tokens = names.map { name in
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { notification in
                if let hint = Self.parseHint(from: notification) {
                    handleHint(hint)
                }
                handleChange()
            }
        }
    }

    func snapshot() async -> NowPlayingSnapshot? {
        await bridge.snapshot()
    }

    func isPlaying() async -> Bool? {
        await bridge.isPlaying()
    }

    func activeBundleIdentifier() async -> String? {
        await bridge.activeBundleIdentifier()
    }

    func send(_ command: MediaCommand, position: Double? = nil) {
        bridge.send(command, position: position)
    }

    private nonisolated static func parseHint(from notification: Notification) -> ImmediatePlaybackHint? {
        let name = notification.name.rawValue
        let info = notification.userInfo
        switch name {
        case "com.apple.Music.playerInfo":
            guard let state = (info?["Player State"] as? String)?.lowercased() else { return nil }
            let isStopped = state == "stopped"
            let isPlaying: Bool? = switch state {
            case "playing": true
            case "paused", "stopped": false
            default: nil
            }
            let title = (info?["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = (info?["Artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (info?["Album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let durationMS = (info?["Total Time"] as? NSNumber)?.doubleValue
            return ImmediatePlaybackHint(
                source: PlayerKind.music.sourceID,
                isPlaying: isPlaying,
                isStopped: isStopped,
                elapsed: nil,
                title: title?.isEmpty == false ? title : nil,
                artist: artist,
                album: album,
                duration: durationMS.map { max(0, $0 / 1000) }
            )

        case "com.spotify.client.PlaybackStateChanged":
            guard let state = (info?["Player State"] as? String)?.lowercased() else { return nil }
            let isStopped = state == "stopped"
            let isPlaying: Bool? = switch state {
            case "playing": true
            case "paused", "stopped": false
            default: nil
            }
            let elapsed = (info?["Playback Position"] as? NSNumber)?.doubleValue
            let title = (info?["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = (info?["Artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (info?["Album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = (info?["Duration"] as? NSNumber)?.doubleValue
            return ImmediatePlaybackHint(
                source: PlayerKind.spotify.sourceID,
                isPlaying: isPlaying,
                isStopped: isStopped,
                elapsed: elapsed,
                title: title?.isEmpty == false ? title : nil,
                artist: artist,
                album: album,
                duration: duration
            )

        case "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification":
            guard let playing = (info?["kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"] as? NSNumber)?.boolValue else {
                return nil
            }
            return ImmediatePlaybackHint(source: nil, isPlaying: playing)

        default:
            return nil
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private extension NowPlayingSnapshot {
    static func parse(_ info: [String: Any], sourceName: String?) -> NowPlayingSnapshot {
        let isMusic = bool(info, "kMRMediaRemoteNowPlayingInfoIsMusicApp")
        let resolvedSource = isMusic ? "Müzik" : sourceName
        let storeID = intID(info, "kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier")
            ?? intID(info, "kMRMediaRemoteNowPlayingInfoiTunesStoreSubscriptionAdamIdentifier")
        return NowPlayingSnapshot(
            title: string(info, "kMRMediaRemoteNowPlayingInfoTitle"),
            artist: string(info, "kMRMediaRemoteNowPlayingInfoArtist"),
            album: string(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
            isMusicApp: isMusic,
            sourceName: resolvedSource,
            artwork: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
            artworkIdentifier: string(info, "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"),
            duration: number(info, "kMRMediaRemoteNowPlayingInfoDuration"),
            elapsed: number(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            rate: number(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            timestamp: info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? .now,
            inTransition: bool(info, "kMRMediaRemoteNowPlayingInfoIsInTransition"),
            storeID: storeID,
            albumStoreID: intID(info, "kMRMediaRemoteNowPlayingInfoAlbumiTunesStoreAdamIdentifier"),
            artistStoreID: intID(info, "kMRMediaRemoteNowPlayingInfoArtistiTunesStoreAdamIdentifier")
        )
    }

    static func string(_ info: [String: Any], _ key: String) -> String {
        (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func number(_ info: [String: Any], _ key: String) -> Double {
        (info[key] as? NSNumber)?.doubleValue ?? 0
    }

    static func bool(_ info: [String: Any], _ key: String) -> Bool {
        (info[key] as? NSNumber)?.boolValue ?? false
    }

    static func intID(_ info: [String: Any], _ key: String) -> Int? {
        if let number = info[key] as? NSNumber {
            let value = number.intValue
            return value > 0 ? value : nil
        }
        if let text = info[key] as? String, let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 {
            return value
        }
        return nil
    }
}

enum ArtworkURL {
    static func highResolutionURL(from identifier: String) -> URL? {
        guard identifier.hasPrefix("https://"),
              var components = URLComponents(string: identifier),
              let host = components.host?.lowercased()
        else { return nil }

        guard host.contains("mzstatic.com") else { return nil }
        guard let range = components.path.range(
            of: #"/\d+x\d+[a-z]*\.(jpg|jpeg|png)$"#,
            options: .regularExpression
        ) else { return nil }
        components.path.replaceSubrange(range, with: "/4000x4000bb.jpg")
        return components.url
    }

    static func sharperData(artist: String, album: String, title: String, identifier: String?) async -> Data? {
        if let identifier, let url = highResolutionURL(from: identifier), let data = await download(url, minimumBytes: 20_000), isSharper(data) {
            return data
        }
        let term = [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return nil }
        for country in ["us", "tr"] {
            guard let match = await catalogMatch(term: term, country: country, artist: artist, album: album, title: title),
                  let artworkURL = match.artworkUrl100,
                  let enlarged = highResolutionURL(from: artworkURL),
                  let image = await download(enlarged, minimumBytes: 20_000),
                  isSharper(image)
            else { continue }
            return image
        }
        return nil
    }

    private static func catalogMatch(
        term: String,
        country: String,
        artist: String,
        album: String,
        title: String
    ) async -> CatalogResponse.Item? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let searchURL = components.url,
              let body = await download(searchURL, minimumBytes: 20),
              let catalog = try? JSONDecoder().decode(CatalogResponse.self, from: body)
        else { return nil }

        let songs = catalog.results.filter { item in
            item.artworkUrl100 != nil
                && titlesMatch(item.trackName, title)
                && artistsMatch(item.artistName, artist)
        }
        if !album.isEmpty {
            return songs.first { albumsMatch($0.collectionName, album) }
        }
        return songs.first
    }

    private static func titlesMatch(_ candidate: String?, _ title: String) -> Bool {
        let left = normalize(candidate ?? "")
        let right = normalize(title)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    private static func artistsMatch(_ candidate: String?, _ artist: String) -> Bool {
        let left = normalize(primaryName(candidate ?? ""))
        let right = normalize(primaryName(artist))
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func albumsMatch(_ candidate: String?, _ album: String) -> Bool {
        let left = normalize(candidate ?? "")
        let right = normalize(album)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func primaryName(_ value: String) -> String {
        var text = value
        if let range = text.range(of: #"\s+(feat\.?|ft\.?|featuring)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(text[..<range.lowerBound])
        }
        if let range = text.range(of: #"\s*[&,x×]\s+"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }
        return text
    }

    private static func normalize(_ value: String) -> String {
        var text = value.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
        text = text.replacingOccurrences(
            of: #"\s*[\(\[].*?[\)\]]"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s*-\s*(single|ep|deluxe|deluxe edition|remaster|remastered|expanded edition|bonus track version)$"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func download(_ url: URL, minimumBytes: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count >= minimumBytes
        else { return nil }
        return data
    }

    private static func isSharper(_ data: Data) -> Bool {
        guard let image = ImageDecoding.cgImage(from: data, maxPixelSize: 4500) else { return false }
        return max(image.width, image.height) >= 1400
    }

    private struct CatalogResponse: Decodable {
        struct Item: Decodable {
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var artworkUrl100: String?
        }

        var results: [Item]
    }
}
