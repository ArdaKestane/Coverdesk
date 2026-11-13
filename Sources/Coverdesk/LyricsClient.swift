import Foundation

struct LyricWord: Equatable, Sendable {
    var text: String
    /// Start time when the source provides one. Empty means the line is shared evenly across its words.
    var time: TimeInterval?
}

struct LyricLine: Equatable, Sendable {
    var time: TimeInterval
    var endTime: TimeInterval? = nil
    var text: String
    var words: [LyricWord] = []

    func spokenWords(until lineEnd: TimeInterval) -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        let tokens = words.isEmpty
            ? text.split(whereSeparator: \.isWhitespace).map { LyricWord(text: String($0), time: nil) }
            : words
        let boundedEnd = endTime.map { min(lineEnd, $0) } ?? lineEnd
        guard !tokens.isEmpty else { return [(text, time, max(boundedEnd, time + 0.25))] }
        let rawEnd = max(boundedEnd, time + 0.28)
        if tokens.contains(where: { $0.time != nil }) {
            return tokens.enumerated().map { index, word in
                let start = word.time ?? time
                let next = index + 1 < tokens.count ? (tokens[index + 1].time ?? rawEnd) : rawEnd
                return (word.text, start, max(next, start + 0.05))
            }
        }

        let rawSpan = rawEnd - time
        let weights = tokens.map { Self.vocalWeight(for: $0.text) }
        let totalWeight = max(0.05, weights.reduce(0, +))
        var maxVocalSpan = totalWeight * 1.28 + 0.18
        if tokens.count <= 4, rawSpan > 5.0 {
            maxVocalSpan = max(maxVocalSpan, min(rawSpan * 0.42, Double(tokens.count) * 0.68))
        }
        let breathTail = min(0.26, rawSpan * 0.12)
        let effectiveSpan = max(0.22, min(max(0.22, rawSpan - breathTail), maxVocalSpan))

        var cursor = time
        return tokens.enumerated().map { index, word in
            let slice = effectiveSpan * (weights[index] / totalWeight)
            let start = cursor
            let finish = cursor + slice
            cursor = finish
            return (word.text, start, max(finish, start + 0.05))
        }
    }

    private static func vocalWeight(for token: String) -> Double {
        var letters = 0
        for scalar in token.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            letters += 1
        }
        let clamped = min(max(1, letters), 12)
        var weight = 0.14 + Double(clamped) * 0.052
        if let last = token.last, ",;:—–.!?…".contains(last) {
            weight += 0.15
        }
        return weight
    }
}

struct LyricsDocument: Equatable, Sendable {
    var lines: [LyricLine]
    var isSynced: Bool

    static let empty = LyricsDocument(lines: [], isSynced: false)

    func index(at elapsed: TimeInterval) -> Int {
        guard !lines.isEmpty else { return 0 }
        var active = 0
        for offset in lines.indices {
            let lineTime = lines[offset].time
            let lead: TimeInterval
            if offset > 0 {
                let gap = max(0, lineTime - lines[offset - 1].time)
                lead = min(0.24, max(0.08, gap * 0.35))
            } else {
                lead = 0.24
            }
            if lineTime <= elapsed + lead {
                active = offset
            }
        }
        return active
    }
}

enum LyricsClient {
    static func fetch(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricsDocument {
        let remote = await fetchLRCLIB(artist: artist, title: title, album: album, duration: duration)
        if remote.isSynced, !remote.lines.isEmpty {
            return remote
        }
        if let music = await PlayerScript.musicLyrics() {
            let parsed = document(from: music, duration: duration)
            if !parsed.lines.isEmpty, parsed.isSynced || remote.lines.isEmpty {
                return parsed
            }
        }
        return remote
    }

    private struct Query {
        var artist: String
        var title: String
        var album: String
        var duration: TimeInterval
    }

    private struct Payload: Decodable {
        var plainLyrics: String?
        var syncedLyrics: String?
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
    }

    private static func fetchLRCLIB(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricsDocument {
        var fallback = LyricsDocument.empty
        for query in variants(artist: artist, title: title, album: album, duration: duration).prefix(4) {
            guard let payload = await get(query) else { continue }
            if let document = document(from: payload, duration: duration), document.isSynced {
                return document
            }
            if fallback.lines.isEmpty, let document = document(from: payload, duration: duration) {
                fallback = document
            }
        }
        if !fallback.isSynced, let found = await search(artist: artist, title: title, album: album, duration: duration) {
            if found.isSynced || fallback.lines.isEmpty { return found }
        }
        return fallback
    }

    private static func document(from payload: Payload, duration: TimeInterval) -> LyricsDocument? {
        if let synced = payload.syncedLyrics {
            let document = LyricsDocument(lines: parseLRC(synced), isSynced: true)
            if !document.lines.isEmpty { return document }
        }
        guard let plain = payload.plainLyrics else { return nil }
        let document = plainDocument(plain, duration: duration)
        return document.lines.isEmpty ? nil : document
    }

    private static func variants(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) -> [Query] {
        var queries = [Query(artist: artist, title: title, album: album, duration: duration)]
        let cleanedArtist = primaryArtist(artist)
        let cleanedTitle = primaryTitle(title)
        if cleanedArtist != artist || cleanedTitle != title {
            queries.append(Query(artist: cleanedArtist, title: cleanedTitle, album: album, duration: duration))
        }
        if !album.isEmpty {
            queries.append(Query(artist: cleanedArtist, title: cleanedTitle, album: "", duration: duration))
        }
        if let lead = creditedNames(artist).first, lead.caseInsensitiveCompare(cleanedArtist) != .orderedSame {
            queries.append(Query(artist: lead, title: cleanedTitle, album: "", duration: duration))
        }
        return queries
    }

    private static func search(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricsDocument? {
        let lead = creditedNames(artist).first ?? artist
        let queries = [
            [
                URLQueryItem(name: "track_name", value: primaryTitle(title)),
                URLQueryItem(name: "artist_name", value: lead)
            ],
            [URLQueryItem(name: "q", value: "\(primaryTitle(title)) \(lead)")]
        ]
        for items in queries {
            guard let hits = await searchHits(items),
                  let match = bestMatch(in: hits, title: title, artist: artist, album: album, duration: duration),
                  let document = document(from: match, duration: duration)
            else { continue }
            return document
        }
        return nil
    }

    private static func searchHits(_ items: [URLQueryItem]) async -> [Payload]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Coverdesk/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode([Payload].self, from: data)
        } catch {
            return nil
        }
    }

    private static func bestMatch(
        in hits: [Payload],
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> Payload? {
        let wantedTitle = normalize(primaryTitle(title))
        let wantedArtists = creditedNames(artist).map(normalize)
        let wantedAlbum = normalize(album)
        var best: (score: Double, payload: Payload)?
        for hit in hits {
            guard normalize(hit.trackName ?? "") == wantedTitle else { continue }
            let names = creditedNames(hit.artistName ?? "").map(normalize)
            let blob = normalize("\(hit.artistName ?? "") \(hit.albumName ?? "")")
            let sharesArtist = wantedArtists.contains { name in
                names.contains(name) || blob.contains(name)
            }
            guard sharesArtist else { continue }
            var score = 0.0
            if let hitDuration = hit.duration, duration > 1 {
                let delta = abs(hitDuration - duration)
                guard delta <= 15 else { continue }
                score += 40 - delta
            }
            if hit.syncedLyrics?.isEmpty == false { score += 3 }
            let hitAlbum = normalize(hit.albumName ?? "")
            if !wantedAlbum.isEmpty, !hitAlbum.isEmpty, hitAlbum.contains(wantedAlbum) || wantedAlbum.contains(hitAlbum) {
                score += 0.4
            }
            if best == nil || score > best?.score ?? -.infinity {
                best = (score, hit)
            }
        }
        return best?.payload
    }

    private static func get(_ query: Query) async -> Payload? {
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist)
        ]
        if !query.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: query.album))
        }
        if query.duration > 1 {
            items.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded()))))
        }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Coverdesk/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(Payload.self, from: data)
        } catch {
            return nil
        }
    }

    private static func document(from text: String, duration: TimeInterval) -> LyricsDocument {
        let synced = parseLRC(text)
        if !synced.isEmpty {
            return LyricsDocument(lines: synced, isSynced: true)
        }
        return plainDocument(text, duration: duration)
    }

    private static func plainDocument(_ text: String, duration: TimeInterval) -> LyricsDocument {
        let rows = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rows.isEmpty else { return .empty }
        let span = duration > 1 ? duration : Double(rows.count) * 4
        let step = span / Double(rows.count)
        let lines = rows.enumerated().map { offset, row in
            LyricLine(time: Double(offset) * step, text: row)
        }
        return LyricsDocument(lines: lines, isSynced: false)
    }

    private static func parseLRC(_ raw: String) -> [LyricLine] {
        struct RawEntry {
            var time: TimeInterval
            var text: String
            var words: [LyricWord]
        }

        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var entries: [RawEntry] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = regex.matches(in: rawLine, range: range)
            guard let last = matches.last else { continue }
            let textStart = last.range.location + last.range.length
            let remainder = textStart < ns.length
                ? ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                : ""
            let words = parseWords(remainder)
            let text = words.isEmpty ? stripTimestamps(remainder) : words.map(\.text).joined(separator: " ")
            for match in matches {
                entries.append(RawEntry(time: timestamp(in: ns, match: match), text: text, words: words))
            }
        }

        let sorted = entries.sorted { $0.time < $1.time }
        var lines: [LyricLine] = []
        lines.reserveCapacity(sorted.count)
        for index in sorted.indices {
            let entry = sorted[index]
            guard !entry.text.isEmpty else { continue }
            var endMarker: TimeInterval?
            for nextIndex in (index + 1)..<sorted.count {
                let candidate = sorted[nextIndex].time
                if candidate > entry.time + 0.08 {
                    endMarker = candidate
                    break
                }
            }
            lines.append(LyricLine(
                time: entry.time,
                endTime: endMarker,
                text: entry.text,
                words: entry.words
            ))
        }
        return lines
    }

    private static func parseWords(_ text: String) -> [LyricWord] {
        let pattern = #"<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>"#
        guard text.contains("<"), let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        var words: [LyricWord] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let finish = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard start <= finish else { continue }
            let word = ns.substring(with: NSRange(location: start, length: finish - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            words.append(LyricWord(text: word, time: timestamp(in: ns, match: match)))
        }
        return words
    }

    private static func stripTimestamps(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(in text: NSString, match: NSTextCheckingResult) -> TimeInterval {
        let minutes = Double(text.substring(with: match.range(at: 1))) ?? 0
        let seconds = Double(text.substring(with: match.range(at: 2))) ?? 0
        var fraction = 0.0
        let fractionRange = match.range(at: 3)
        if fractionRange.location != NSNotFound {
            let digits = text.substring(with: fractionRange)
            fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
        }
        return minutes * 60 + seconds + fraction
    }

    private static func primaryArtist(_ artist: String) -> String {
        creditedNames(artist).first ?? artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func creditedNames(_ artist: String) -> [String] {
        var text = artist
        for token in [" feat. ", " feat ", " ft. ", " ft ", " & ", " x ", ","] {
            text = text.replacingOccurrences(of: token, with: "\n", options: .caseInsensitive)
        }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func primaryTitle(_ title: String) -> String {
        guard let range = title.range(of: " (") else { return title }
        return String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
