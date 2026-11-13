import AppKit
import CryptoKit
import Foundation
import iTunesLibrary

enum LibraryBlock: Error, Equatable, Sendable {
    case notRunning
    case automation
    case failed
}

enum LibraryStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable(LibraryBlock)
}

enum SearchScope: String, Equatable, Sendable {
    case library
    case appleMusic

    var title: String {
        switch self {
        case .library: "Kitaplık"
        case .appleMusic: "Apple Music"
        }
    }
}

enum CatalogState: Equatable, Sendable {
    case idle
    case loading
    case failed
}

struct LibraryPlaylist: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var title: String
    var titleFold: String
    var trackIDs: [String]
    var totalDuration: TimeInterval
    var coverTrackID: String?
    var isFavourites: Bool

    init(
        id: String,
        title: String,
        trackIDs: [String],
        totalDuration: TimeInterval = 0,
        coverTrackID: String? = nil,
        isFavourites: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleFold = LibraryMatch.keys(title).spaced
        self.trackIDs = trackIDs
        self.totalDuration = totalDuration
        self.coverTrackID = coverTrackID ?? trackIDs.first
        self.isFavourites = isFavourites
    }

    var formattedSubtitle: String {
        let countText = "\(trackIDs.count) şarkı"
        guard totalDuration >= 60 else { return countText }
        let minutes = Int((totalDuration / 60).rounded())
        if minutes >= 60 {
            let hours = minutes / 60
            let rem = minutes % 60
            return rem > 0 ? "\(countText) · \(hours) sa \(rem) dk" : "\(countText) · \(hours) sa"
        }
        return "\(countText) · \(minutes) dk"
    }
}

struct SearchHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    enum EntryKind: String, Codable, Equatable, Sendable {
        case query
        case song
        case album
        case artist
        case playlist
    }

    var id: String
    var entryKind: EntryKind
    var query: String
    var scopeRaw: String
    var title: String
    var subtitle: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var songCount: Int
    var persistentID: String?
    var playlistID: String?
    var isPlaylistOnly: Bool
    var storeID: Int?
    var artistID: Int?
    var collectionID: Int?
    var artworkURLString: String?
    var artworkKey: String
    var libraryArtID: String?
    var timestamp: Date

    var scope: SearchScope {
        SearchScope(rawValue: scopeRaw) ?? .library
    }

    var asSearchItem: SearchItem? {
        let kind: SearchKind
        switch entryKind {
        case .query: return nil
        case .song: kind = .song
        case .album: kind = .album
        case .artist: kind = .artist
        case .playlist: kind = .playlist
        }
        return SearchItem(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            artist: artist,
            album: album,
            duration: duration,
            trackNumber: 0,
            songCount: songCount,
            persistentID: persistentID,
            playlistID: playlistID,
            isPlaylistOnly: isPlaylistOnly,
            storeID: storeID,
            artistID: artistID,
            collectionID: collectionID,
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            artworkKey: artworkKey,
            libraryArtID: libraryArtID
        )
    }

    static func fromItem(_ item: SearchItem, query: String, scope: SearchScope) -> SearchHistoryEntry {
        let entryKind: EntryKind = switch item.kind {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        }
        return SearchHistoryEntry(
            id: item.id,
            entryKind: entryKind,
            query: query,
            scopeRaw: scope.rawValue,
            title: item.title,
            subtitle: item.subtitle,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            songCount: item.songCount,
            persistentID: item.persistentID,
            playlistID: item.resolvedPlaylistID,
            isPlaylistOnly: item.isPlaylistOnly,
            storeID: item.storeID,
            artistID: item.resolvedArtistID,
            collectionID: item.resolvedCollectionID,
            artworkURLString: item.artworkURL?.absoluteString,
            artworkKey: item.artworkKey,
            libraryArtID: item.libraryArtID,
            timestamp: .now
        )
    }

    static func fromQuery(_ rawQuery: String, scope: SearchScope) -> SearchHistoryEntry {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let fold = LibraryMatch.keys(trimmed).spaced
        return SearchHistoryEntry(
            id: "history-query-\(scope.rawValue)-\(fold)",
            entryKind: .query,
            query: trimmed,
            scopeRaw: scope.rawValue,
            title: trimmed,
            subtitle: scope.title,
            artist: "",
            album: "",
            duration: 0,
            songCount: 0,
            persistentID: nil,
            playlistID: nil,
            isPlaylistOnly: false,
            storeID: nil,
            artistID: nil,
            collectionID: nil,
            artworkURLString: nil,
            artworkKey: "",
            libraryArtID: nil,
            timestamp: .now
        )
    }
}

enum SearchHistoryStore {
    private static var fileURL: URL {
        LibraryDiskCache.supportDirectory.appendingPathComponent("search-history.json")
    }

    static func load() async -> [SearchHistoryEntry] {
        let url = fileURL
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data)
            else { return [] }
            return Array(entries.prefix(16))
        }.value
    }

    static func save(_ entries: [SearchHistoryEntry]) {
        let trimmed = Array(entries.prefix(16))
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct LibraryTrack: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var titleFold: String
    var artistFold: String
    var albumFold: String
    var titleSqueezed: String
    var blob: String
    var blobSqueezed: String
    var storeID: Int?
    var remoteArtworkURL: URL?
    var trackNumber: Int
    var isPlaylistOnly: Bool

    init(
        id: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        storeID: Int? = nil,
        remoteArtworkURL: URL? = nil,
        trackNumber: Int = 0,
        isPlaylistOnly: Bool = false
    ) {
        let titleKeys = LibraryMatch.keys(title)
        let artistKeys = LibraryMatch.keys(artist)
        let albumKeys = LibraryMatch.keys(album)
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        titleFold = titleKeys.spaced
        artistFold = artistKeys.spaced
        albumFold = albumKeys.spaced
        titleSqueezed = titleKeys.squeezed
        blob = [titleKeys.spaced, artistKeys.spaced, albumKeys.spaced]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        blobSqueezed = titleKeys.squeezed + artistKeys.squeezed + albumKeys.squeezed
        self.storeID = storeID
        self.remoteArtworkURL = remoteArtworkURL
        self.trackNumber = trackNumber
        self.isPlaylistOnly = isPlaylistOnly
    }

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum SearchKind: String, Equatable, Sendable {
    case song
    case album
    case artist
    case playlist

    var sectionTitle: String {
        switch self {
        case .song: "Şarkılar"
        case .album: "Albümler"
        case .artist: "Sanatçılar"
        case .playlist: "Listeler"
        }
    }
}

struct SearchItem: Identifiable, Equatable, Sendable {
    var id: String
    var kind: SearchKind
    var title: String
    var subtitle: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var trackNumber: Int
    var songCount: Int
    var persistentID: String?
    var playlistID: String? = nil
    var isPlaylistOnly: Bool = false
    var storeID: Int?
    var artistID: Int?
    var collectionID: Int?
    var artworkURL: URL?
    var artworkKey: String
    var libraryArtID: String?

    var resolvedArtistID: Int? {
        artistID ?? id.catalogIdentifier(after: "catalog-artist-")
    }

    var resolvedCollectionID: Int? {
        collectionID ?? id.catalogIdentifier(after: "catalog-album-")
    }

    var resolvedPlaylistID: String? {
        if let playlistID, !playlistID.isEmpty { return playlistID }
        if id.hasPrefix("library-playlist-") {
            return String(id.dropFirst("library-playlist-".count))
        }
        return nil
    }

    static func albumKey(artist: String, album: String) -> String {
        let artistKey = LibraryMatch.keys(artist).spaced
        let albumKey = LibraryMatch.keys(album).spaced
        guard !artistKey.isEmpty || !albumKey.isEmpty else { return "" }
        return "album:\(artistKey)|\(albumKey)"
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        let left = LibraryMatch.keys(lhs).spaced
        let right = LibraryMatch.keys(rhs).spaced
        return !left.isEmpty && left == right
    }

    static func looseMatch(_ lhs: String, _ rhs: String) -> Bool {
        if sameName(lhs, rhs) { return true }
        let left = strippedName(lhs)
        let right = strippedName(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shorter = min(left.count, right.count)
        guard shorter >= 3 else { return false }
        return left.hasPrefix(right) || right.hasPrefix(left) || left.contains(right) || right.contains(left)
    }

    private static func strippedName(_ value: String) -> String {
        var cleaned = value
        cleaned = cleaned.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*-\s*(single|ep|deluxe.*|remaster.*)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if let comma = cleaned.firstIndex(of: ",") {
            let lead = String(cleaned[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            if lead.count >= 2 { cleaned = lead }
        }
        return LibraryMatch.keys(cleaned).spaced
    }
}

private extension String {
    func catalogIdentifier(after prefix: String) -> Int? {
        guard hasPrefix(prefix) else { return nil }
        return Int(dropFirst(prefix.count))
    }
}

enum LibraryMatch {
    static func tokens(in query: String) -> [String] {
        keys(query).spaced.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    static func matches(in tracks: [LibraryTrack], query: String, limit: Int) -> [LibraryTrack] {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return [] }
        let phrase = tokens.joined(separator: " ")
        let squeezed = tokens.joined()
        var ranked: [(score: Int, length: Int, track: LibraryTrack)] = []
        ranked.reserveCapacity(min(tracks.count, 64))
        for track in tracks {
            guard let score = score(track, tokens: tokens, phrase: phrase, squeezed: squeezed) else { continue }
            ranked.append((score, track.titleFold.count, track))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.track.titleFold < rhs.track.titleFold
        }
        if ranked.count <= limit {
            return ranked.map(\.track)
        }
        return ranked.prefix(limit).map(\.track)
    }

    static func ranges(in text: String, tokens: [String]) -> [Range<String.Index>] {
        let scanned = scan(text)
        var found: [Range<String.Index>] = []
        for token in tokens where !token.isEmpty {
            let spaced = locate(token, in: scanned.spaced, text: text)
            if spaced.isEmpty {
                found.append(contentsOf: locate(token, in: scanned.squeezed, text: text))
            } else {
                found.append(contentsOf: spaced)
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func keys(_ value: String) -> (spaced: String, squeezed: String) {
        let scanned = scan(value)
        return (scanned.spaced.text, scanned.squeezed.text)
    }

    static func nameScore(_ fold: String, tokens: [String], phrase: String) -> Int? {
        guard !fold.isEmpty, !tokens.isEmpty else { return nil }
        let squeezedQuery = tokens.joined()
        let squeezedFold = fold.replacingOccurrences(of: " ", with: "")
        if fold == phrase || (!squeezedQuery.isEmpty && squeezedFold == squeezedQuery) { return 0 }
        if fold.hasPrefix(phrase) || (tokens.count == 1 && squeezedFold.hasPrefix(squeezedQuery)) { return 1 }
        if fold.contains(" " + phrase) { return 2 }
        let words = fold.split(separator: " ").map(String.init)
        if tokens.allSatisfy({ token in words.contains(where: { $0.hasPrefix(token) }) }) { return 3 }
        if fold.contains(phrase) || tokens.allSatisfy({ fold.contains($0) || squeezedFold.contains($0) }) { return 4 }
        return nil
    }

    private static func score(
        _ track: LibraryTrack,
        tokens: [String],
        phrase: String,
        squeezed: String
    ) -> Int? {
        guard tokens.allSatisfy({ track.blob.contains($0) || track.blobSqueezed.contains($0) }) else { return nil }
        if track.titleFold == phrase || (!squeezed.isEmpty && track.titleSqueezed == squeezed) { return 0 }
        if track.titleFold.hasPrefix(phrase) || (tokens.count == 1 && track.titleSqueezed.hasPrefix(squeezed)) { return 1 }
        if track.titleFold.contains(phrase) { return 2 }
        if tokens.allSatisfy({ track.titleFold.contains($0) || track.titleSqueezed.contains($0) }) { return 3 }
        if track.artistFold.hasPrefix(phrase) || track.artistFold.contains(phrase) { return 4 }
        if tokens.allSatisfy({ track.artistFold.contains($0) }) { return 5 }
        if track.albumFold.hasPrefix(phrase) || tokens.allSatisfy({ track.albumFold.contains($0) }) { return 6 }
        return 7
    }

    private struct CharMap {
        var text = ""
        var origins: [String.Index] = []
    }

    private static func scan(_ text: String) -> (spaced: CharMap, squeezed: CharMap) {
        var spaced = CharMap()
        var squeezed = CharMap()
        var pendingSpace = false
        for index in text.indices {
            let character = text[index]
            let piece = foldedPiece(character)
            if piece.isEmpty {
                if !isGlue(character) {
                    pendingSpace = !spaced.text.isEmpty
                }
                continue
            }
            if pendingSpace {
                spaced.text.append(" ")
                spaced.origins.append(index)
                pendingSpace = false
            }
            for folded in piece {
                spaced.text.append(folded)
                spaced.origins.append(index)
                squeezed.text.append(folded)
                squeezed.origins.append(index)
            }
        }
        if spaced.text.last == " " {
            spaced.text.removeLast()
            spaced.origins.removeLast()
        }
        return (spaced, squeezed)
    }

    private static func locate(_ token: String, in map: CharMap, text: String) -> [Range<String.Index>] {
        guard !map.origins.isEmpty, !token.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = map.text.startIndex
        while start < map.text.endIndex, let found = map.text.range(of: token, range: start..<map.text.endIndex) {
            let lower = map.text.distance(from: map.text.startIndex, to: found.lowerBound)
            let upper = map.text.distance(from: map.text.startIndex, to: found.upperBound) - 1
            if lower >= 0, upper >= lower, upper < map.origins.count {
                let startIndex = map.origins[lower]
                let endIndex = text.index(after: map.origins[upper])
                if startIndex < endIndex {
                    ranges.append(startIndex..<endIndex)
                }
            }
            if found.upperBound <= start { break }
            start = found.upperBound
        }
        return ranges
    }

    private static func foldedPiece(_ character: Character) -> String {
        var piece = ""
        for lower in String(character).lowercased(with: Locale(identifier: "tr")) {
            switch lower {
            case "ı", "i":
                piece.append("i")
            case "ş":
                piece.append("s")
            case "ğ":
                piece.append("g")
            case "ü":
                piece.append("u")
            case "ö":
                piece.append("o")
            case "ç":
                piece.append("c")
            default:
                if lower.isASCII, lower.isLetter || lower.isNumber {
                    piece.append(lower)
                    continue
                }
                let folded = String(lower).folding(
                    options: .diacriticInsensitive,
                    locale: Locale(identifier: "en_US_POSIX")
                )
                for item in folded {
                    if item.isASCII, item.isLetter || item.isNumber {
                        piece.append(item)
                    }
                }
            }
        }
        return piece
    }

    private static func isGlue(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "ʼ" || character == "`" || character == "´"
    }
}

actor LibraryIndex {
    private var tracks: [LibraryTrack] = []
    private var playlists: [LibraryPlaylist] = []
    private var byID: [String: LibraryTrack] = [:]
    private var byStoreID: [Int: LibraryTrack] = [:]
    private var playlistByTrackID: [String: String] = [:]
    private(set) var fetchedAt: Date?

    var count: Int { tracks.count + playlists.count }
    var trackCount: Int { tracks.count }

    func replace(_ tracks: [LibraryTrack], playlists: [LibraryPlaylist] = [], fetchedAt: Date) {
        self.tracks = tracks
        self.playlists = playlists
        var idMap: [String: LibraryTrack] = [:]
        idMap.reserveCapacity(tracks.count)
        var storeMap: [Int: LibraryTrack] = [:]
        storeMap.reserveCapacity(tracks.count)
        for track in tracks {
            idMap[track.id] = track
            if let storeID = track.storeID, storeID > 0 {
                if let existing = storeMap[storeID] {
                    if existing.isPlaylistOnly && !track.isPlaylistOnly {
                        storeMap[storeID] = track
                    }
                } else {
                    storeMap[storeID] = track
                }
            }
        }
        var trackPlaylistMap: [String: String] = [:]
        for playlist in playlists {
            for trackID in playlist.trackIDs where trackPlaylistMap[trackID] == nil {
                trackPlaylistMap[trackID] = playlist.id
            }
        }
        byID = idMap
        byStoreID = storeMap
        playlistByTrackID = trackPlaylistMap
        self.fetchedAt = fetchedAt
    }

    func search(_ query: String, limit: Int = 20) -> [LibraryTrack] {
        LibraryMatch.matches(in: tracks, query: query, limit: limit)
    }

    func track(forPersistentID id: String) -> LibraryTrack? {
        byID[id]
    }

    func track(forStoreID storeID: Int) -> LibraryTrack? {
        guard storeID > 0 else { return nil }
        return byStoreID[storeID]
    }

    func containingPlaylistID(for trackID: String) -> String? {
        playlistByTrackID[trackID]
    }

    /// Resolves a song to a local library/playlist track so Music can start it without opening a window.
    func track(storeID: Int? = nil, title: String, artist: String, album: String) -> LibraryTrack? {
        if let storeID, storeID > 0, let direct = byStoreID[storeID] {
            return direct
        }
        let titleFold = LibraryMatch.keys(title).spaced
        let artistFold = LibraryMatch.keys(artist).spaced
        let albumFold = LibraryMatch.keys(album).spaced
        let matches = tracks.filter { track in
            (titleFold.isEmpty || track.titleFold == titleFold)
                && (artistFold.isEmpty || track.artistFold == artistFold)
                && (albumFold.isEmpty || track.albumFold == albumFold)
        }
        return matches.min { lhs, rhs in
            if lhs.isPlaylistOnly != rhs.isPlaylistOnly {
                return !lhs.isPlaylistOnly
            }
            let left = lhs.trackNumber == 0 ? Int.max : lhs.trackNumber
            let right = rhs.trackNumber == 0 ? Int.max : rhs.trackNumber
            return left < right
        }
    }

    func allPlaylists() -> [SearchItem] {
        playlists
            .filter { !$0.trackIDs.isEmpty }
            .map { makePlaylistItem($0, prefixLabel: false) }
    }

    func listing(for query: String) -> [SearchItem] {
        let tokens = LibraryMatch.tokens(in: query)
        guard !tokens.isEmpty else { return [] }
        let phrase = tokens.joined(separator: " ")
        let artists = artistHits(tokens: tokens, phrase: phrase)
        let strongArtists = Set(artists.filter { $0.score <= 1 }.map(\.fold))
        let albums = albumHits(tokens: tokens, phrase: phrase, strongArtists: strongArtists)
        let lists = playlistHits(tokens: tokens, phrase: phrase)
        let songs = LibraryMatch.matches(in: tracks, query: query, limit: 12).map { Self.songItem($0) }
        return artists.map(\.item) + albums.map(\.item) + lists.map(\.item) + songs
    }

    func artistPage(named artist: String) -> (songs: [SearchItem], albums: [SearchItem]) {
        let fold = LibraryMatch.keys(artist).spaced
        let mine = tracks.filter { $0.artistFold == fold }
        let albums = albumItems(from: mine, limit: 12)
        let songs = mine
            .sorted(by: songOrder)
            .prefix(30)
            .map { Self.songItem($0) }
        return (Array(songs), albums)
    }

    func albumPage(artist: String, album: String) -> [SearchItem] {
        let artistFold = LibraryMatch.keys(artist).spaced
        let albumFold = LibraryMatch.keys(album).spaced
        let exact = tracks.filter {
            (artistFold.isEmpty || $0.artistFold == artistFold) && $0.albumFold == albumFold
        }
        let chosen = exact.isEmpty ? tracks.filter { $0.albumFold == albumFold } : exact
        return chosen
            .sorted(by: songOrder)
            .map { Self.songItem($0) }
    }

    func playlistPage(id: String) -> [SearchItem] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        return playlist.trackIDs.enumerated().compactMap { offset, trackID in
            guard let track = byID[trackID] else { return nil }
            var item = Self.songItem(track)
            item.id = "plsong-\(id)-\(offset)-\(track.id)"
            item.playlistID = id
            return item
        }
    }

    private struct NamedHit {
        var score: Int
        var fold: String
        var item: SearchItem
    }

    private func makePlaylistItem(_ playlist: LibraryPlaylist, prefixLabel: Bool) -> SearchItem {
        let cover = playlist.coverTrackID.flatMap { byID[$0] }
            ?? playlist.trackIDs.compactMap { byID[$0] }.first
        let subtitle = prefixLabel
            ? "Liste · \(playlist.formattedSubtitle)"
            : playlist.formattedSubtitle
        return SearchItem(
            id: "library-playlist-\(playlist.id)",
            kind: .playlist,
            title: playlist.title,
            subtitle: subtitle,
            artist: cover?.artist ?? "",
            album: cover?.album ?? "",
            duration: playlist.totalDuration,
            trackNumber: 0,
            songCount: playlist.trackIDs.count,
            persistentID: nil,
            playlistID: playlist.id,
            storeID: nil,
            artistID: nil,
            collectionID: nil,
            artworkURL: nil,
            artworkKey: "playlist-cover:\(playlist.id)",
            libraryArtID: cover?.id
        )
    }

    private func playlistHits(tokens: [String], phrase: String) -> [NamedHit] {
        var hits: [NamedHit] = []
        for playlist in playlists where !playlist.titleFold.isEmpty && !playlist.trackIDs.isEmpty {
            guard let score = LibraryMatch.nameScore(playlist.titleFold, tokens: tokens, phrase: phrase) else { continue }
            hits.append(NamedHit(
                score: score,
                fold: playlist.titleFold,
                item: makePlaylistItem(playlist, prefixLabel: true)
            ))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
        }
        return Array(hits.prefix(3))
    }

    private func artistHits(tokens: [String], phrase: String) -> [NamedHit] {
        var groups: [String: [LibraryTrack]] = [:]
        for track in tracks where !track.artistFold.isEmpty {
            groups[track.artistFold, default: []].append(track)
        }
        var hits: [NamedHit] = []
        for (fold, group) in groups {
            guard let score = LibraryMatch.nameScore(fold, tokens: tokens, phrase: phrase) else { continue }
            let name = Self.preferredName(group.map(\.artist))
            guard !name.isEmpty else { continue }
            let cover = Self.coverTrack(in: group)
            hits.append(NamedHit(
                score: score,
                fold: fold,
                item: SearchItem(
                    id: "library-artist-\(fold)",
                    kind: .artist,
                    title: name,
                    subtitle: "Sanatçı · \(group.count) şarkı",
                    artist: name,
                    album: cover.album,
                    duration: 0,
                    trackNumber: 0,
                    songCount: group.count,
                    persistentID: nil,
                    storeID: nil,
                    artistID: nil,
                    collectionID: nil,
                    artworkURL: nil,
                    artworkKey: Self.artKey(artist: name, album: cover.album, fallback: cover.id),
                    libraryArtID: cover.id
                )
            ))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.item.songCount != rhs.item.songCount { return lhs.item.songCount > rhs.item.songCount }
            return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
        }
        return Array(hits.prefix(3))
    }

    private func albumHits(tokens: [String], phrase: String, strongArtists: Set<String>) -> [NamedHit] {
        var groups: [String: [LibraryTrack]] = [:]
        for track in tracks where !track.albumFold.isEmpty {
            groups["\(track.artistFold)\u{1f}\(track.albumFold)", default: []].append(track)
        }
        var hits: [NamedHit] = []
        for (key, group) in groups {
            let sample = group[0]
            let named = LibraryMatch.nameScore(sample.albumFold, tokens: tokens, phrase: phrase)
            let viaArtist = strongArtists.contains(sample.artistFold)
            guard named != nil || viaArtist else { continue }
            let album = Self.preferredName(group.map(\.album))
            let artist = Self.preferredName(group.map(\.artist))
            guard !album.isEmpty else { continue }
            hits.append(NamedHit(
                score: named ?? 5,
                fold: key,
                item: Self.albumItem(id: "library-album-\(key)", title: album, artist: artist, tracks: group)
            ))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.item.songCount != rhs.item.songCount { return lhs.item.songCount > rhs.item.songCount }
            return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
        }
        return Array(hits.prefix(4))
    }

    private func albumItems(from tracks: [LibraryTrack], limit: Int) -> [SearchItem] {
        var groups: [String: [LibraryTrack]] = [:]
        for track in tracks where !track.albumFold.isEmpty {
            groups[track.albumFold, default: []].append(track)
        }
        let albums = groups.map { fold, group in
            Self.albumItem(
                id: "library-album-\(group[0].artistFold)\u{1f}\(fold)",
                title: Self.preferredName(group.map(\.album)),
                artist: Self.preferredName(group.map(\.artist)),
                tracks: group
            )
        }
        .sorted { lhs, rhs in
            if lhs.songCount != rhs.songCount { return lhs.songCount > rhs.songCount }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return Array(albums.prefix(limit))
    }

    private func songOrder(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        if lhs.albumFold != rhs.albumFold {
            return lhs.albumFold.localizedStandardCompare(rhs.albumFold) == .orderedAscending
        }
        let left = lhs.trackNumber > 0 ? lhs.trackNumber : Int.max
        let right = rhs.trackNumber > 0 ? rhs.trackNumber : Int.max
        if left != right { return left < right }
        return lhs.titleFold.localizedStandardCompare(rhs.titleFold) == .orderedAscending
    }

    private static func albumItem(id: String, title: String, artist: String, tracks: [LibraryTrack]) -> SearchItem {
        let cover = coverTrack(in: tracks)
        let count = tracks.count
        return SearchItem(
            id: id,
            kind: .album,
            title: title,
            subtitle: artist.isEmpty ? "Albüm" : "Albüm · \(artist)",
            artist: artist,
            album: title,
            duration: 0,
            trackNumber: 0,
            songCount: count,
            persistentID: nil,
            storeID: nil,
            artistID: nil,
            collectionID: nil,
            artworkURL: nil,
            artworkKey: artKey(artist: artist, album: title, fallback: cover.id),
            libraryArtID: cover.id
        )
    }

    private static func songItem(_ track: LibraryTrack) -> SearchItem {
        SearchItem(
            id: track.id,
            kind: .song,
            title: track.title,
            subtitle: track.subtitle,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            trackNumber: track.trackNumber,
            songCount: 0,
            persistentID: track.id,
            isPlaylistOnly: track.isPlaylistOnly,
            storeID: track.storeID,
            artistID: nil,
            collectionID: nil,
            artworkURL: track.remoteArtworkURL,
            artworkKey: artKey(artist: track.artist, album: track.album, fallback: track.id),
            libraryArtID: track.id
        )
    }

    private static func coverTrack(in tracks: [LibraryTrack]) -> LibraryTrack {
        let grouped = Dictionary(grouping: tracks.filter { !$0.albumFold.isEmpty }, by: \.albumFold)
        let richest = grouped.max { $0.value.count < $1.value.count }?.value.first
        return richest ?? tracks[0]
    }

    private static func artKey(artist: String, album: String, fallback: String) -> String {
        let key = SearchItem.albumKey(artist: artist, album: album)
        return key.isEmpty ? "song:\(fallback)" : key
    }

    private static func preferredName(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            counts[trimmed, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        }?.key ?? ""
    }
}

enum LibraryDiskCache {
    private struct Snapshot: Codable {
        var version: Int
        var fetchedAt: Date
        var tracks: [StoredTrack]
        var playlists: [LibraryPlaylist]
    }

    private struct StoredTrack: Codable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var trackNumber: Int
        var storeID: Int?
        var isPlaylistOnly: Bool

        private enum CodingKeys: String, CodingKey {
            case id, title, artist, album, duration, trackNumber, storeID, isPlaylistOnly
        }

        init(
            id: String,
            title: String,
            artist: String,
            album: String,
            duration: TimeInterval,
            trackNumber: Int,
            storeID: Int?,
            isPlaylistOnly: Bool
        ) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.trackNumber = trackNumber
            self.storeID = storeID
            self.isPlaylistOnly = isPlaylistOnly
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            artist = try container.decode(String.self, forKey: .artist)
            album = try container.decode(String.self, forKey: .album)
            duration = try container.decode(TimeInterval.self, forKey: .duration)
            trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
            storeID = try container.decodeIfPresent(Int.self, forKey: .storeID)
            isPlaylistOnly = try container.decodeIfPresent(Bool.self, forKey: .isPlaylistOnly) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(artist, forKey: .artist)
            try container.encode(album, forKey: .album)
            try container.encode(duration, forKey: .duration)
            try container.encode(trackNumber, forKey: .trackNumber)
            try container.encodeIfPresent(storeID, forKey: .storeID)
            try container.encode(isPlaylistOnly, forKey: .isPlaylistOnly)
        }
    }

    static func load() async -> (tracks: [LibraryTrack], playlists: [LibraryPlaylist], fetchedAt: Date)? {
        let url = fileURL
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == 3
            else { return nil }
            let tracks = snapshot.tracks.compactMap { stored -> LibraryTrack? in
                let title = stored.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stored.id.isEmpty, !title.isEmpty else { return nil }
                return LibraryTrack(
                    id: stored.id,
                    title: title,
                    artist: stored.artist,
                    album: stored.album,
                    duration: stored.duration,
                    storeID: stored.storeID,
                    trackNumber: stored.trackNumber,
                    isPlaylistOnly: stored.isPlaylistOnly
                )
            }
            guard !tracks.isEmpty else { return nil }
            return (tracks, snapshot.playlists, snapshot.fetchedAt)
        }.value
    }

    static func save(_ tracks: [LibraryTrack], playlists: [LibraryPlaylist], fetchedAt: Date) async {
        let snapshot = Snapshot(
            version: 3,
            fetchedAt: fetchedAt,
            tracks: tracks.map {
                StoredTrack(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist,
                    album: $0.album,
                    duration: $0.duration,
                    trackNumber: $0.trackNumber,
                    storeID: $0.storeID,
                    isPlaylistOnly: $0.isPlaylistOnly
                )
            },
            playlists: playlists
        )
        let url = fileURL
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }.value
    }

    private static var fileURL: URL {
        supportDirectory.appendingPathComponent("library.json")
    }

    static func cachedArtwork(forKey key: String) -> URL {
        supportDirectory
            .appendingPathComponent("search-art", isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
            .appendingPathComponent(artworkFilename(key))
    }

    static func legacyArtwork(id: String) -> URL {
        supportDirectory
            .appendingPathComponent("search-art", isDirectory: true)
            .appendingPathComponent(id)
    }

    private static func artworkFilename(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static var supportDirectory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coverdesk", isDirectory: true)
        return directory
    }
}

private enum CatalogFailure: Error {
    case notRunning
    case automationDenied
    case failed

    var block: LibraryBlock {
        switch self {
        case .notRunning: .notRunning
        case .automationDenied: .automation
        case .failed: .failed
        }
    }
}

private final class ITLibraryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var itemsByID: [String: ITLibMediaItem] = [:]
    private var playlistsByID: [String: ITLibPlaylist] = [:]

    func store(items: [String: ITLibMediaItem], playlists: [String: ITLibPlaylist]) {
        lock.lock()
        itemsByID = items
        playlistsByID = playlists
        lock.unlock()
    }

    func artworkData(for id: String) -> Data? {
        lock.lock()
        let item = itemsByID[id]
        lock.unlock()
        guard let data = item?.artwork?.imageData, data.count > 32 else { return nil }
        return data
    }

    func playlistArtworkData(for id: String) -> Data? {
        lock.lock()
        let playlist = playlistsByID[id]
        lock.unlock()
        guard let playlist,
              playlist.responds(to: NSSelectorFromString("artwork")),
              let artwork = playlist.value(forKey: "artwork") as? ITLibArtwork,
              let data = artwork.imageData,
              data.count > 32
        else { return nil }
        return data
    }
}

enum LibraryCatalog {
    private static let queue = DispatchQueue(label: "com.coverdesk.library")
    private static let itLibraryBox = ITLibraryBox()

    static func fetchLibrary() async -> Result<(tracks: [LibraryTrack], playlists: [LibraryPlaylist]), LibraryBlock> {
        await withCheckedContinuation { continuation in
            queue.async {
                if let native = readITLibrary() {
                    continuation.resume(returning: .success(native))
                    return
                }
                continuation.resume(returning: readLibrary().map { ($0, []) }.mapError(\.block))
            }
        }
    }

    static func playlistArtworkData(id: String) -> Data? {
        guard isPersistentID(id) else { return nil }
        return itLibraryBox.playlistArtworkData(for: id)
    }

    static func artworkData(id: String) async -> Data? {
        guard isPersistentID(id) else { return nil }
        if let direct = itLibraryBox.artworkData(for: id) {
            return direct
        }
        let url = artworkURL(id)
        if let cached = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: url) }).value,
           cached.count > 32 {
            return cached
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                if let direct = itLibraryBox.artworkData(for: id) {
                    continuation.resume(returning: direct)
                    return
                }
                continuation.resume(returning: fetchArtwork(id: id, to: url))
            }
        }
    }

    /// Reads the entire Music library and playlists directly from `iTunesLibrary.framework` in ~0.35s
    /// even when Music.app is closed, with zero AppleScript or Automation overhead.
    private static func readITLibrary() -> (tracks: [LibraryTrack], playlists: [LibraryPlaylist])? {
        guard let library = try? ITLibrary(apiVersion: "1.1") else { return nil }
        let rawItems = library.allMediaItems.filter { $0.mediaKind == .kindSong }
        var seen: Set<String> = []
        var tracks: [LibraryTrack] = []
        var itemMap: [String: ITLibMediaItem] = [:]
        var durationMap: [String: TimeInterval] = [:]
        tracks.reserveCapacity(rawItems.count)
        itemMap.reserveCapacity(rawItems.count)
        durationMap.reserveCapacity(rawItems.count)

        for item in rawItems {
            let id = String(format: "%016llX", item.persistentID.uint64Value)
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(id).inserted else { continue }
            itemMap[id] = item
            let artist = (item.artist?.name ?? item.album.albumArtist ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (item.album.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = max(0, Double(item.totalTime) / 1000)
            durationMap[id] = duration
            let storeID = positiveInt(item, key: "storeItemID") ?? positiveInt(item, key: "subscriptionAdamID")
            let playlistOnly = (item.value(forKey: "isPlaylistOnly") as? NSNumber)?.boolValue ?? false
            tracks.append(LibraryTrack(
                id: id,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                storeID: storeID,
                trackNumber: max(0, item.trackNumber),
                isPlaylistOnly: playlistOnly
            ))
        }

        var playlists: [LibraryPlaylist] = []
        var playlistMap: [String: ITLibPlaylist] = [:]
        for playlist in library.allPlaylists {
            guard !playlist.isMaster,
                  playlist.isVisible,
                  playlist.kind != .folder,
                  playlist.distinguishedKind == .kindNone || playlist.distinguishedKind.rawValue == 52
            else { continue }
            let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let trackIDs = playlist.items
                .filter { $0.mediaKind == .kindSong }
                .map { String(format: "%016llX", $0.persistentID.uint64Value) }
                .filter { seen.contains($0) }
            guard !trackIDs.isEmpty else { continue }
            let pid = String(format: "%016llX", playlist.persistentID.uint64Value)
            playlistMap[pid] = playlist
            let totalDuration = trackIDs.reduce(0) { $0 + (durationMap[$1] ?? 0) }
            playlists.append(LibraryPlaylist(
                id: pid,
                title: name,
                trackIDs: trackIDs,
                totalDuration: totalDuration,
                isFavourites: playlist.distinguishedKind.rawValue == 52
            ))
        }
        itLibraryBox.store(items: itemMap, playlists: playlistMap)
        return (tracks, playlists)
    }

    private static func positiveInt(_ object: NSObject, key: String) -> Int? {
        guard object.responds(to: NSSelectorFromString(key)),
              let number = object.value(forKey: key) as? NSNumber
        else { return nil }
        let value = number.intValue
        return value > 0 ? value : nil
    }

    private static func readLibrary() -> Result<[LibraryTrack], CatalogFailure> {
        guard PlayerScript.isRunning(.music) else { return .failure(.notRunning) }
        switch runLibraryScript(songsOnly: true) {
        case .success(let tracks):
            return .success(tracks)
        case .failure(.automationDenied):
            return .failure(.automationDenied)
        case .failure:
            return runLibraryScript(songsOnly: false)
        }
    }

    private static func runLibraryScript(songsOnly: Bool) -> Result<[LibraryTrack], CatalogFailure> {
        let filter = songsOnly ? " whose media kind is song" : ""
        let source = """
        tell application "Music"
            if not running then return ""
            set lib to library playlist 1
            set idList to persistent ID of every track of lib\(filter)
            set nameList to name of every track of lib\(filter)
            set artistList to artist of every track of lib\(filter)
            set albumList to album of every track of lib\(filter)
            set durationList to duration of every track of lib\(filter)
            set numberList to track number of every track of lib\(filter)
            return {idList, nameList, artistList, albumList, durationList, numberList}
        end tell
        """
        return execute(source).flatMap(parseLibrary)
    }

    private static func parseLibrary(_ descriptor: NSAppleEventDescriptor) -> Result<[LibraryTrack], CatalogFailure> {
        guard descriptor.numberOfItems >= 5,
              let ids = strings(from: descriptor.atIndex(1)),
              let names = strings(from: descriptor.atIndex(2)),
              let artists = strings(from: descriptor.atIndex(3)),
              let albums = strings(from: descriptor.atIndex(4)),
              let durations = doubles(from: descriptor.atIndex(5))
        else { return .failure(.failed) }
        let numbers = ints(from: descriptor.atIndex(6)) ?? []
        let count = min(ids.count, names.count, artists.count, albums.count, durations.count)
        var seen: Set<String> = []
        var tracks: [LibraryTrack] = []
        tracks.reserveCapacity(count)
        for index in 0..<count {
            let id = ids[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = names[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPersistentID(id), !title.isEmpty, seen.insert(id).inserted else { continue }
            tracks.append(LibraryTrack(
                id: id,
                title: title,
                artist: artists[index].trimmingCharacters(in: .whitespacesAndNewlines),
                album: albums[index].trimmingCharacters(in: .whitespacesAndNewlines),
                duration: max(0, durations[index]),
                trackNumber: index < numbers.count ? max(0, numbers[index]) : 0
            ))
        }
        return .success(tracks)
    }

    private static func fetchArtwork(id: String, to url: URL) -> Data? {
        let path = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = """
        tell application "Music"
            if not running then return ""
            set fileRef to missing value
            try
                set theTrack to first track of library playlist 1 whose persistent ID is "\(id)"
                set artData to data of artwork 1 of theTrack
                set fileRef to open for access POSIX file "\(path)" with write permission
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
        guard case .success(let descriptor) = execute(source),
              descriptor.stringValue == "ok",
              let data = try? Data(contentsOf: url),
              data.count > 32
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    private static func execute(_ source: String) -> Result<NSAppleEventDescriptor, CatalogFailure> {
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let number = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if number == -1743 { return .failure(.automationDenied) }
            return .failure(.failed)
        }
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if number == -1743 { return .failure(.automationDenied) }
            return .failure(.failed)
        }
        return .success(descriptor)
    }

    private static func strings(from descriptor: NSAppleEventDescriptor?) -> [String]? {
        guard let descriptor else { return nil }
        if descriptor.descriptorType != typeAEList {
            return [descriptor.stringValue ?? ""]
        }
        let count = descriptor.numberOfItems
        guard count > 0 else { return [] }
        var values: [String] = []
        values.reserveCapacity(count)
        for index in 1...count {
            values.append(descriptor.atIndex(index)?.stringValue ?? "")
        }
        return values
    }

    private static func doubles(from descriptor: NSAppleEventDescriptor?) -> [Double]? {
        guard let descriptor else { return nil }
        if descriptor.descriptorType != typeAEList {
            return [doubleValue(descriptor)]
        }
        let count = descriptor.numberOfItems
        guard count > 0 else { return [] }
        var values: [Double] = []
        values.reserveCapacity(count)
        for index in 1...count {
            values.append(doubleValue(descriptor.atIndex(index)))
        }
        return values
    }

    private static func ints(from descriptor: NSAppleEventDescriptor?) -> [Int]? {
        guard let descriptor else { return nil }
        if descriptor.descriptorType != typeAEList {
            return [intValue(descriptor)]
        }
        let count = descriptor.numberOfItems
        guard count > 0 else { return [] }
        var values: [Int] = []
        values.reserveCapacity(count)
        for index in 1...count {
            values.append(intValue(descriptor.atIndex(index)))
        }
        return values
    }

    private static func intValue(_ descriptor: NSAppleEventDescriptor?) -> Int {
        guard let descriptor else { return 0 }
        if let text = descriptor.stringValue {
            let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(digits) { return value }
        }
        return Int(descriptor.int32Value)
    }

    private static func doubleValue(_ descriptor: NSAppleEventDescriptor?) -> Double {
        guard let descriptor else { return 0 }
        let direct = descriptor.doubleValue
        if direct != 0, direct.isFinite { return direct }
        if let text = descriptor.stringValue {
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            if let value = Double(normalized), value.isFinite { return value }
        }
        let intValue = descriptor.int32Value
        if intValue != 0 { return Double(intValue) }
        return direct.isFinite ? direct : 0
    }

    private static func artworkURL(_ id: String) -> URL {
        LibraryDiskCache.supportDirectory
            .appendingPathComponent("search-art", isDirectory: true)
            .appendingPathComponent(id)
    }

    private static func isPersistentID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
    }
}

enum CatalogSearch {
    static func listing(matching query: String) async -> [SearchItem]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        async let artists = fetch(term: trimmed, entity: "musicArtist", limit: 8)
        async let albums = fetch(term: trimmed, entity: "album", limit: 8)
        async let songs = fetch(term: trimmed, entity: "song", limit: 12)
        let artistItems = await artists
        let albumItems = await albums
        let songItems = await songs
        if artistItems == nil, albumItems == nil, songItems == nil { return nil }
        return assemble(
            query: trimmed,
            artists: artistItems ?? [],
            albums: albumItems ?? [],
            songs: songItems ?? []
        )
    }

    static func artistPage(artistID: Int?, name: String) async -> (songs: [SearchItem], albums: [SearchItem])? {
        async let songsTask = collected(id: artistID, name: name, entity: "song", lookupLimit: 30, searchLimit: 30)
        async let albumsTask = collected(id: artistID, name: name, entity: "album", lookupLimit: 20, searchLimit: 20)
        let songs = await songsTask
        let albums = await albumsTask
        if songs == nil, albums == nil { return nil }
        let songRows = songs ?? []
        let albumRows = albums ?? []
        let art = artworkByArtist(albums: albumRows, songs: songRows)
        let mappedSongs = filtered(songRows, artist: name).compactMap { songItem(from: $0, artistArt: art) }
        let mappedAlbums = filtered(albumRows, artist: name).compactMap { albumItem(from: $0, artistArt: art) }
        return (unique(mappedSongs).prefix(25).map { $0 }, unique(mappedAlbums).prefix(12).map { $0 })
    }

    static func albumPage(collectionID: Int?, title: String, artist: String) async -> [SearchItem]? {
        var rows: [Item] = []
        if let collectionID, let found = await lookup(id: collectionID, entity: "song", limit: 80) {
            rows = found
        }
        if rows.isEmpty {
            let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            if let found = await fetch(term: term, entity: "song", limit: 50) {
                rows = found
            }
        }
        if rows.isEmpty { return collectionID == nil ? nil : [] }
        let matched = rows.filter { item in
            let song = item.trackName?.isEmpty == false
            guard song else { return false }
            if let collectionID, item.collectionId == collectionID { return true }
            let albumMatches = title.isEmpty || SearchItem.looseMatch(item.collectionName ?? "", title)
            let artistMatches = artist.isEmpty || SearchItem.looseMatch(item.artistName ?? "", artist)
            return albumMatches && artistMatches
        }
        let chosen = matched.isEmpty ? rows : matched
        return unique(chosen.compactMap { songItem(from: $0, artistArt: [:]) })
            .sorted { lhs, rhs in
                let left = lhs.trackNumber > 0 ? lhs.trackNumber : Int.max
                let right = rhs.trackNumber > 0 ? rhs.trackNumber : Int.max
                if left != right { return left < right }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static func remoteArtwork(artist: String, album: String, title: String) async -> URL? {
        let albumName = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = [artist, albumName.isEmpty ? title : albumName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return nil }
        let entity = albumName.isEmpty ? "song" : "album"
        guard let items = await fetch(term: term, entity: entity, limit: 6) else { return nil }
        let match = items.first { item in
            if entity == "album" {
                return namesMatch(item.collectionName, albumName) && namesMatch(item.artistName, artist)
            }
            return namesMatch(item.trackName, title) && namesMatch(item.artistName, artist)
        }
        return artworkURL(from: match?.artworkUrl100)
    }

    static func artistArtwork(artistID: Int) async -> URL? {
        guard let albums = await lookup(id: artistID, entity: "album", limit: 1) else { return nil }
        return artworkURL(from: albums.first?.artworkUrl100)
    }

    static func artworkData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 32
        else { return nil }
        return data
    }

    private static func assemble(
        query: String,
        artists: [Item],
        albums: [Item],
        songs: [Item]
    ) -> [SearchItem] {
        let tokens = LibraryMatch.tokens(in: query)
        let phrase = tokens.joined(separator: " ")
        let art = artworkByArtist(albums: albums, songs: songs)
        let mappedArtists = unique(artists.compactMap { artistItem(from: $0, artistArt: art) })
        var artistHits = mappedArtists
            .enumerated()
            .compactMap { index, item -> (Int, SearchItem)? in
                if let score = LibraryMatch.nameScore(LibraryMatch.keys(item.title).spaced, tokens: tokens, phrase: phrase) {
                    return (score, item)
                }
                if index < 2 { return (6 + index, item) }
                return nil
            }
            .sorted { $0.0 < $1.0 }
            .prefix(3)
            .map(\.1)
        if artistHits.isEmpty, let first = mappedArtists.first {
            artistHits = [first]
        }

        let strongArtists = Set(artistHits.map { LibraryMatch.keys($0.artist).spaced })
        let mappedAlbums = unique(albums.compactMap { albumItem(from: $0, artistArt: art) })
        let albumHits = mappedAlbums
            .enumerated()
            .compactMap { index, item -> (Int, SearchItem)? in
                let albumScore = LibraryMatch.nameScore(LibraryMatch.keys(item.album).spaced, tokens: tokens, phrase: phrase)
                let artistFold = LibraryMatch.keys(item.artist).spaced
                if let albumScore { return (albumScore, item) }
                if strongArtists.contains(artistFold) || LibraryMatch.nameScore(artistFold, tokens: tokens, phrase: phrase) != nil {
                    return (5, item)
                }
                if index < 2 { return (7 + index, item) }
                return nil
            }
            .sorted { $0.0 < $1.0 }
            .prefix(4)
            .map(\.1)
        let songHits = unique(songs.compactMap { songItem(from: $0, artistArt: art) }).prefix(12)
        return artistHits + albumHits + Array(songHits)
    }

    private static func collected(id: Int?, name: String, entity: String, lookupLimit: Int, searchLimit: Int) async -> [Item]? {
        if let id, let found = await lookup(id: id, entity: entity, limit: lookupLimit), !found.isEmpty {
            return found
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await fetch(term: trimmed, entity: entity, limit: searchLimit, attribute: "artistTerm")
    }

    private static func filtered(_ items: [Item], artist: String) -> [Item] {
        let exact = items.filter { SearchItem.looseMatch($0.artistName ?? "", artist) }
        return exact.isEmpty ? items : exact
    }

    private static func unique(_ items: [SearchItem]) -> [SearchItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func fetch(term: String, entity: String, limit: Int, attribute: String? = nil) async -> [Item]? {
        for country in ["tr", "us"] {
            guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
            var query = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "entity", value: entity),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "media", value: "music"),
            ]
            if let attribute {
                query.append(URLQueryItem(name: "attribute", value: attribute))
            }
            components.queryItems = query
            guard let url = components.url else { continue }
            if let results = await load(url), !results.isEmpty {
                return results
            }
            if country == "us" {
                return await load(url)
            }
        }
        return nil
    }

    private static func lookup(id: Int, entity: String, limit: Int) async -> [Item]? {
        for country in ["tr", "us"] {
            guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
            components.queryItems = [
                URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "entity", value: entity),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "country", value: country),
            ]
            guard let url = components.url else { continue }
            if let results = await load(url)?.filter({ $0.wrapperType != "artist" }), !results.isEmpty {
                return results
            }
        }
        return nil
    }

    private static func load(_ url: URL) async -> [Item]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(Payload.self, from: data).results
        } catch {
            return nil
        }
    }

    private static func artistItem(from item: Item, artistArt: [Int: URL]) -> SearchItem? {
        let name = item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let artistID = item.artistId, !name.isEmpty else { return nil }
        let artwork = artistArt[artistID]
        return SearchItem(
            id: "catalog-artist-\(artistID)",
            kind: .artist,
            title: name,
            subtitle: "Sanatçı",
            artist: name,
            album: "",
            duration: 0,
            trackNumber: 0,
            songCount: 0,
            persistentID: nil,
            storeID: nil,
            artistID: artistID,
            collectionID: nil,
            artworkURL: artwork,
            artworkKey: artwork?.absoluteString ?? "artist:\(artistID)",
            libraryArtID: nil
        )
    }

    private static func albumItem(from item: Item, artistArt: [Int: URL]) -> SearchItem? {
        let title = item.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let collectionID = item.collectionId, !title.isEmpty, item.wrapperType != "artist" else { return nil }
        let artist = item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = artworkURL(from: item.artworkUrl100) ?? item.artistId.flatMap { artistArt[$0] }
        return SearchItem(
            id: "catalog-album-\(collectionID)",
            kind: .album,
            title: title,
            subtitle: artist.isEmpty ? "Albüm" : "Albüm · \(artist)",
            artist: artist,
            album: title,
            duration: 0,
            trackNumber: 0,
            songCount: item.trackCount ?? 0,
            persistentID: nil,
            storeID: nil,
            artistID: item.artistId,
            collectionID: collectionID,
            artworkURL: artwork,
            artworkKey: artKey(artist: artist, album: title, artwork: artwork, fallback: "album-\(collectionID)"),
            libraryArtID: nil
        )
    }

    private static func songItem(from item: Item, artistArt: [Int: URL]) -> SearchItem? {
        let title = item.trackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let storeID = item.trackId, !title.isEmpty else { return nil }
        let artist = item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = item.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = artworkURL(from: item.artworkUrl100) ?? item.artistId.flatMap { artistArt[$0] }
        return SearchItem(
            id: "catalog-song-\(storeID)",
            kind: .song,
            title: title,
            subtitle: [artist, album].filter { !$0.isEmpty }.joined(separator: " · "),
            artist: artist,
            album: album,
            duration: Double(item.trackTimeMillis ?? 0) / 1000,
            trackNumber: item.trackNumber ?? 0,
            songCount: 0,
            persistentID: nil,
            storeID: storeID,
            artistID: item.artistId,
            collectionID: item.collectionId,
            artworkURL: artwork,
            artworkKey: artKey(artist: artist, album: album, artwork: artwork, fallback: "song-\(storeID)"),
            libraryArtID: nil
        )
    }

    private static func artworkByArtist(albums: [Item], songs: [Item]) -> [Int: URL] {
        var art: [Int: URL] = [:]
        for item in albums + songs {
            guard let artistID = item.artistId, art[artistID] == nil, let url = artworkURL(from: item.artworkUrl100) else { continue }
            art[artistID] = url
        }
        return art
    }

    private static func artKey(artist: String, album: String, artwork: URL?, fallback: String) -> String {
        if let artwork { return artwork.absoluteString }
        let key = SearchItem.albumKey(artist: artist, album: album)
        return key.isEmpty ? "song:\(fallback)" : key
    }

    private static func artworkURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let enlarged = raw.replacingOccurrences(of: "100x100bb", with: "300x300bb")
        return URL(string: enlarged)
    }

    private static func namesMatch(_ candidate: String?, _ expected: String) -> Bool {
        let left = LibraryMatch.keys(candidate ?? "").spaced
        let right = LibraryMatch.keys(expected).spaced
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private struct Payload: Decodable {
        var results: [Item]

        private enum CodingKeys: String, CodingKey {
            case results
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var nested = try container.nestedUnkeyedContainer(forKey: .results)
            var decoded: [Item] = []
            while !nested.isAtEnd {
                if let item = try? nested.decode(Item.self) {
                    decoded.append(item)
                } else {
                    _ = try nested.decode(Discard.self)
                }
            }
            results = decoded
        }
    }

    private struct Discard: Decodable {}

    private struct Item: Decodable {
        var wrapperType: String?
        var artistId: Int?
        var artistName: String?
        var collectionId: Int?
        var collectionName: String?
        var trackId: Int?
        var trackName: String?
        var trackTimeMillis: Int?
        var trackNumber: Int?
        var trackCount: Int?
        var artworkUrl100: String?
    }
}
