import AppKit
import Foundation
import ServiceManagement

enum OverlayMode: Equatable, Sendable {
    case none
    case search
    case playlists
}

@MainActor
@Observable
final class AppModel {
    let preferences = Preferences()

    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var subtitle = "Apple Music, Spotify ya da tarayıcı"
    private(set) var lyrics = LyricsDocument.empty
    private(set) var lyricsResolved = false
    private(set) var sourceName = ""
    private(set) var artwork: NSImage?
    private(set) var artworkToken = ""
    private(set) var trackID = ""
    private(set) var clock = PlaybackClock()
    private(set) var currentStoreID: Int?
    private(set) var currentPlayingPlaylistID: String?
    private(set) var isPreparingPlayback = false
    private(set) var statusMessage: String?
    private(set) var isAvailable = true
    private(set) var overlayMode: OverlayMode = .none
    private(set) var searchFocusToken = 0
    private(set) var searchQuery = ""
    private(set) var settledSearchQuery = ""
    private(set) var searchResults: [SearchItem] = []
    private(set) var searchSelection = 0
    private(set) var searchHistory: [SearchHistoryEntry] = []
    private(set) var searchArtwork: [String: NSImage] = [:]
    private(set) var libraryStatus: LibraryStatus = .idle
    private(set) var libraryCount = 0
    private(set) var searchScope: SearchScope = .library
    private(set) var catalogState: CatalogState = .idle
    private(set) var searchStack: [SearchItem] = []
    private(set) var detailSongs: [SearchItem] = []
    private(set) var detailAlbums: [SearchItem] = []
    private(set) var detailState: CatalogState = .idle
    private(set) var savedPlaylists: [SearchItem] = []
    private(set) var activePlaylistPage: SearchItem?
    private(set) var activePlaylistSongs: [SearchItem] = []
    private(set) var playlistSelection = 0

    var isSearchPresented: Bool { overlayMode == .search }
    var isPlaylistsPresented: Bool { overlayMode == .playlists }
    var isOverlayPresented: Bool { overlayMode != .none }

    var isShowingSearchHistory: Bool {
        isSearchPresented
            && searchStack.isEmpty
            && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !searchHistory.isEmpty
    }

    var searchFocusItems: [SearchItem] {
        guard let page = searchStack.last else { return searchResults }
        switch page.kind {
        case .album, .playlist:
            return detailSongs
        case .artist:
            return detailSongs + detailAlbums
        case .song:
            return searchResults
        }
    }

    var playlistFocusItems: [SearchItem] {
        activePlaylistPage != nil ? activePlaylistSongs : savedPlaylists
    }

    var onInterfaceChange: (() -> Void)?
    var onPlaybackChange: (() -> Void)?
    var onWallpaperReady: (([RenderedWallpaper]) -> Void)?
    var onSearchChange: (() -> Void)?
    var onSearchFocus: (() -> Void)?
    private(set) var generation = 0

    private let nowPlaying = NowPlayingCenter()
    private let wallpaper = WallpaperController()
    private var renderTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var settleRefreshTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var appearanceTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var latestArtwork = Data()
    private var hasArtwork = false
    private var hasClock = false
    private var isRefreshing = false
    private var refreshAgain = false
    private var renderedScreenKey = ""
    private var currentArtworkIdentity = ""
    private var playbackSource = "system"
    private var commandIssuedAt = Date.distantPast
    private var transportHold: TimeInterval = 1.5
    private var transportIntent: TransportIntent?
    private var catalogWait: CatalogWait?
    private var confirmTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var optimisticArtTask: Task<Void, Never>?
    private var playbackRequestID: UInt64 = 0
    private var activePlaybackKey = ""
    private var activePlaybackStartedAt = Date.distantPast
    private var queryRecordedInHistory = ""

    private struct TransportIntent {
        var rate: Double?
        var rejectTrackID: String?
        var elapsed: TimeInterval
        var pinElapsed: Bool
    }

    private struct CatalogWait {
        var until: Date
        var kind: SearchKind
        var title: String
        var artist: String
        var album: String
        var storeIDs: Set<Int>
        var collectionID: Int?
        var artistID: Int?
        var previousTrackID: String
    }
    private var loadedLyricsTrack = ""
    private var emptyReads = 0
    private var screenTask: Task<Void, Never>?
    private let libraryIndex = LibraryIndex()
    private var libraryTask: Task<Void, Never>?
    private var libraryRefreshAgain = false
    private var libraryFetchedAt: Date?
    private var libraryFailedAt: Date?
    private var searchGeneration = 0
    private var detailGeneration = 0
    private var detailCache: [String: (songs: [SearchItem], albums: [SearchItem])] = [:]
    private var artworkTask: Task<Void, Never>?
    private var artworkQueue: [SearchArtJob] = []
    private var artworkMisses: Set<String> = []

    func start() {
        isAvailable = nowPlaying.isAvailable
        searchScope = preferences.searchScope
        preferences.onInterfaceChange = { [weak self] in
            self?.onInterfaceChange?()
        }
        preferences.onAppearanceChange = { [weak self] in
            self?.syncIdleWallpaper()
            self?.debouncedRender()
        }
        wallpaper.rememberOriginals()
        PlayerScript.setAutomationDeniedHandler { [weak self] in
            Task { @MainActor in
                self?.isPreparingPlayback = false
                self?.catalogWait = nil
                self?.statusMessage = "Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon bölümünden Coverdesk’in Müzik’i denetlemesine izin ver."
                self?.subtitle = "Otomasyon izni gerekli"
                self?.publishPlayback()
            }
        }
        nowPlaying.start(
            onImmediateHint: { [weak self] hint in
                Task { @MainActor in
                    self?.handleImmediateHint(hint)
                }
            },
            onChange: { [weak self] in
                Task { @MainActor in
                    self?.refreshNow()
                    self?.scheduleSettleRefresh(after: .milliseconds(220))
                }
            }
        )
        Task { [weak self] in
            let history = await SearchHistoryStore.load()
            guard let self else { return }
            self.searchHistory = history
            self.prefetchHistoryArtwork()
            if self.isSearchPresented { self.onSearchChange?() }
        }
        prepareLibrarySearch()
        scheduleRefresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let fast = self?.isPreparingPlayback == true
                try? await Task.sleep(for: fast ? .milliseconds(250) : .seconds(1))
                await self?.refresh()
            }
        }
    }

    func prepareForQuit() {
        renderTask?.cancel()
        refreshTask?.cancel()
        settleRefreshTask?.cancel()
        upgradeTask?.cancel()
        lyricsTask?.cancel()
        pollTask?.cancel()
        libraryTask?.cancel()
        artworkTask?.cancel()
        playbackTask?.cancel()
        optimisticArtTask?.cancel()
        if preferences.restoreOnQuit {
            wallpaper.restoreOriginals()
        }
    }

    func screensChanged() {
        onInterfaceChange?()
        screenTask?.cancel()
        screenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            let screenKey = self.targetSpecs().map { "\($0.displayID):\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: ",")
            guard screenKey != self.renderedScreenKey else { return }
            self.wallpaper.invalidate()
            self.scheduleRender()
        }
    }

    func playPause() {
        if isPreparingPlayback {
            playbackRequestID &+= 1
            playbackTask?.cancel()
            playbackTask = nil
            isPreparingPlayback = false
            catalogWait = nil
            clock.rate = 0
            publishPlayback()
            if PlayerScript.isRunning(.music) || playbackSource != PlayerKind.music.sourceID {
                send(.pause)
            }
            return
        }
        let shouldPlay = !clock.isPlaying
        let action: TransportAction = shouldPlay ? .play : .pause
        if shouldRouteTransportToColdMusic(for: action) {
            performColdMusicTransport(action)
            return
        }
        let now = Date()
        clock.anchorElapsed = clock.elapsed(at: now)
        clock.anchorDate = now
        clock.rate = shouldPlay ? 1 : 0
        publishPlayback()
        send(action)
        scheduleTransportConfirmation()
    }

    func next() {
        if shouldRouteTransportToColdMusic(for: .next) {
            performColdMusicTransport(.next)
            return
        }
        send(.next)
        scheduleTransportConfirmation()
    }

    func previous() {
        if shouldRouteTransportToColdMusic(for: .previous) {
            performColdMusicTransport(.previous)
            return
        }
        send(.previous)
        scheduleTransportConfirmation()
    }

    func seek(to seconds: TimeInterval) {
        let upper = clock.duration > 1 ? clock.duration : max(0, seconds)
        let target = min(max(0, seconds), upper)
        clock.anchorElapsed = target
        clock.anchorDate = .now
        if shouldRouteTransportToColdMusic(for: .seek(target)) {
            performColdMusicTransport(.seek(target))
            return
        }
        publishPlayback()
        send(.seek(target))
        scheduleTransportConfirmation()
    }

    func seek(toFraction fraction: Double) {
        guard clock.duration > 1 else { return }
        seek(to: clock.duration * min(1, max(0, fraction)))
    }

    func toggleSearch() {
        if overlayMode == .search {
            collapseOverlay()
        } else {
            presentSearch()
        }
    }

    func presentSearch() {
        let opening = overlayMode != .search
        overlayMode = .search
        searchFocusToken &+= 1
        if opening {
            if isShowingSearchHistory {
                prefetchHistoryArtwork()
            } else {
                let visible = searchStack + searchFocusItems
                if !visible.isEmpty { prefetchArtwork(visible) }
            }
            onSearchChange?()
        }
        onSearchFocus?()
        if case .unavailable(.notRunning) = libraryStatus {
            openMusicForSearch()
        } else {
            prepareLibrarySearch()
        }
    }

    func togglePlaylists() {
        if overlayMode == .playlists {
            collapseOverlay()
        } else {
            presentPlaylists()
        }
    }

    func presentPlaylists() {
        if overlayMode == .search {
            recordCurrentQueryIfNeeded()
        }
        let opening = overlayMode != .playlists
        overlayMode = .playlists
        if case .unavailable(.notRunning) = libraryStatus {
            openMusicForSearch()
        } else if let libraryFetchedAt, Date().timeIntervalSince(libraryFetchedAt) > 15 {
            refreshLibraryIfNeeded(force: true)
        } else {
            prepareLibrarySearch()
        }
        let visible = [activePlaylistPage].compactMap { $0 } + playlistFocusItems
        if !visible.isEmpty {
            prefetchArtwork(Array(visible.prefix(32)))
        }
        if opening { onSearchChange?() }
        onSearchFocus?()
    }

    func refreshPlaylists() {
        refreshLibraryIfNeeded(force: true)
    }

    /// Collapses the floating card WITHOUT wiping search query, search results, or navigation state,
    /// so switching to another app (like Chrome) or reopening Search restores everything immediately.
    func collapseOverlay() {
        guard overlayMode != .none else { return }
        if overlayMode == .search {
            recordCurrentQueryIfNeeded()
        }
        overlayMode = .none
        onSearchChange?()
    }

    func dismissSearch() {
        collapseOverlay()
    }

    /// Clears the current search text & results (triggered by the `✕` button inside the search field)
    /// and reveals Search History (`Son Aramalar`).
    func clearSearchQuery() {
        recordCurrentQueryIfNeeded()
        searchQuery = ""
        settledSearchQuery = ""
        searchResults = []
        searchSelection = 0
        catalogState = .idle
        searchGeneration += 1
        queryRecordedInHistory = ""
        resetSearchNavigation()
        prefetchHistoryArtwork()
        searchFocusToken &+= 1
        onSearchChange?()
        onSearchFocus?()
    }

    func popSearchPage() {
        guard isSearchPresented else { return }
        guard !searchStack.isEmpty else {
            collapseOverlay()
            return
        }
        searchStack.removeLast()
        searchSelection = 0
        detailGeneration += 1
        if let page = searchStack.last {
            showDetail(page)
        } else {
            detailSongs = []
            detailAlbums = []
            detailState = .idle
            if isShowingSearchHistory {
                prefetchHistoryArtwork()
            }
            onSearchChange?()
        }
        searchFocusToken &+= 1
        onSearchFocus?()
    }

    func popPlaylistPage() {
        guard isPlaylistsPresented else { return }
        guard let previous = activePlaylistPage else {
            collapseOverlay()
            return
        }
        activePlaylistPage = nil
        activePlaylistSongs = []
        if let idx = savedPlaylists.firstIndex(where: { $0.id == previous.id }) {
            playlistSelection = idx
        } else {
            playlistSelection = 0
        }
        onSearchChange?()
    }

    func cancelOverlay() {
        switch overlayMode {
        case .none:
            break
        case .search:
            popSearchPage()
        case .playlists:
            popPlaylistPage()
        }
    }

    func setSearchScope(_ scope: SearchScope) {
        guard scope != searchScope else { return }
        recordCurrentQueryIfNeeded()
        searchScope = scope
        preferences.searchScope = scope
        searchSelection = 0
        catalogState = .idle
        queryRecordedInHistory = ""
        resetSearchNavigation()
        searchFocusToken &+= 1
        onSearchChange?()
        onSearchFocus?()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            settledSearchQuery = ""
            prefetchHistoryArtwork()
            onSearchChange?()
            return
        }
        refilterSearch()
    }

    func toggleSearchScope() {
        setSearchScope(searchScope == .library ? .appleMusic : .library)
    }

    func prepareLibrarySearch() {
        refreshLibraryIfNeeded(force: false)
    }

    func setSearchQuery(_ query: String) {
        let clipped = String(query.prefix(80))
        guard clipped != searchQuery else { return }
        searchQuery = clipped
        queryRecordedInHistory = ""
        resetSearchNavigation()
        let trimmed = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchSelection = 0
            settledSearchQuery = ""
            catalogState = .idle
            prefetchHistoryArtwork()
            onSearchChange?()
            return
        }
        refilterSearch()
    }

    func moveOverlaySelection(by delta: Int) {
        switch overlayMode {
        case .none:
            return
        case .search:
            let count = isShowingSearchHistory ? searchHistory.count : searchFocusItems.count
            guard count > 0 else { return }
            let next = min(max(0, searchSelection + delta), count - 1)
            guard next != searchSelection else { return }
            searchSelection = next
            onSearchChange?()
        case .playlists:
            let items = playlistFocusItems
            guard !items.isEmpty else { return }
            let next = min(max(0, playlistSelection + delta), items.count - 1)
            guard next != playlistSelection else { return }
            playlistSelection = next
            onSearchChange?()
        }
    }

    func moveSearchSelection(by delta: Int) {
        moveOverlaySelection(by: delta)
    }

    func submitOverlaySelection(direct: Bool = false) {
        switch overlayMode {
        case .none:
            return
        case .search:
            if isShowingSearchHistory {
                guard searchHistory.indices.contains(searchSelection) else { return }
                let entry = searchHistory[searchSelection]
                if direct {
                    playHistoryEntryDirectly(entry)
                } else {
                    selectHistoryEntry(entry)
                }
                return
            }
            let items = searchFocusItems
            guard items.indices.contains(searchSelection) else { return }
            let item = items[searchSelection]
            if direct {
                playSearchItem(item, dismissAfter: searchStack.isEmpty)
            } else {
                selectSearchItem(item)
            }
        case .playlists:
            let items = playlistFocusItems
            guard items.indices.contains(playlistSelection) else { return }
            let item = items[playlistSelection]
            if activePlaylistPage == nil {
                if direct {
                    playPlaylist(item, shuffled: false)
                } else {
                    openPlaylist(item)
                }
            } else {
                playPlaylistSong(item)
            }
        }
    }

    func playSelectedSearchResult() {
        submitOverlaySelection(direct: false)
    }

    func playSelectedSearchResultDirectly() {
        submitOverlaySelection(direct: true)
    }

    func selectSearchItem(_ item: SearchItem) {
        if let idx = searchFocusItems.firstIndex(where: { $0.id == item.id }) {
            searchSelection = idx
        }
        if overlayMode == .search, searchStack.isEmpty {
            recordItemInHistory(item)
        }
        switch item.kind {
        case .song:
            playSearchItem(item, dismissAfter: searchStack.isEmpty)
        case .artist, .album, .playlist:
            searchStack.append(item)
            searchSelection = 0
            showDetail(item)
        }
    }

    // MARK: - Search History

    func selectHistoryEntry(_ entry: SearchHistoryEntry) {
        if entry.entryKind == .query {
            bumpHistoryEntry(entry)
            if entry.scope != searchScope {
                searchScope = entry.scope
                preferences.searchScope = entry.scope
            }
            searchQuery = entry.query
            queryRecordedInHistory = entry.query
            resetSearchNavigation()
            searchFocusToken &+= 1
            onSearchFocus?()
            refilterSearch()
            return
        }
        guard let item = entry.asSearchItem else { return }
        bumpHistoryEntry(entry)
        if item.kind == .song {
            playSearchItem(item, dismissAfter: true)
        } else {
            if entry.scope != searchScope {
                searchScope = entry.scope
                preferences.searchScope = entry.scope
            }
            searchStack = [item]
            searchSelection = 0
            showDetail(item)
        }
    }

    func playHistoryEntryDirectly(_ entry: SearchHistoryEntry) {
        if entry.entryKind == .query {
            selectHistoryEntry(entry)
            return
        }
        guard let item = entry.asSearchItem else { return }
        bumpHistoryEntry(entry)
        playSearchItem(item, dismissAfter: item.kind == .song)
    }

    func removeSearchHistory(_ id: String) {
        searchHistory.removeAll { $0.id == id }
        if searchSelection >= searchHistory.count {
            searchSelection = max(0, searchHistory.count - 1)
        }
        SearchHistoryStore.save(searchHistory)
        onSearchChange?()
    }

    func clearSearchHistory() {
        searchHistory = []
        searchSelection = 0
        SearchHistoryStore.save([])
        onSearchChange?()
    }

    private func recordItemInHistory(_ item: SearchItem) {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SearchHistoryEntry.fromItem(item, query: trimmedQuery, scope: searchScope)
        if !trimmedQuery.isEmpty {
            queryRecordedInHistory = trimmedQuery
        }
        let queryFold = LibraryMatch.keys(trimmedQuery).spaced
        searchHistory.removeAll { existing in
            if existing.id == entry.id { return true }
            if existing.entryKind == .query, !queryFold.isEmpty {
                let existingFold = LibraryMatch.keys(existing.query).spaced
                if existingFold == queryFold || queryFold.hasPrefix(existingFold) {
                    return true
                }
            }
            return false
        }
        searchHistory.insert(entry, at: 0)
        if searchHistory.count > 15 {
            searchHistory = Array(searchHistory.prefix(15))
        }
        SearchHistoryStore.save(searchHistory)
    }

    private func recordCurrentQueryIfNeeded() {
        let trimmed = settledSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !searchResults.isEmpty else { return }
        guard trimmed.caseInsensitiveCompare(queryRecordedInHistory) != .orderedSame else { return }
        queryRecordedInHistory = trimmed
        let entry = SearchHistoryEntry.fromQuery(trimmed, scope: searchScope)
        let newFold = LibraryMatch.keys(trimmed).spaced
        searchHistory.removeAll { existing in
            if existing.id == entry.id { return true }
            guard existing.entryKind == .query, existing.scope == searchScope else { return false }
            let oldFold = LibraryMatch.keys(existing.query).spaced
            return !oldFold.isEmpty && (newFold.hasPrefix(oldFold) || oldFold.hasPrefix(newFold))
        }
        searchHistory.insert(entry, at: 0)
        if searchHistory.count > 15 {
            searchHistory = Array(searchHistory.prefix(15))
        }
        SearchHistoryStore.save(searchHistory)
    }

    private func bumpHistoryEntry(_ entry: SearchHistoryEntry) {
        var updated = entry
        updated.timestamp = .now
        searchHistory.removeAll { $0.id == entry.id }
        searchHistory.insert(updated, at: 0)
        SearchHistoryStore.save(searchHistory)
    }

    private func prefetchHistoryArtwork() {
        let items = searchHistory.compactMap(\.asSearchItem)
        if !items.isEmpty {
            prefetchArtwork(items)
        }
    }

    // MARK: - Saved Playlists Drawer

    func openPlaylist(_ item: SearchItem) {
        guard item.kind == .playlist else { return }
        activePlaylistPage = item
        playlistSelection = 0
        activePlaylistSongs = []
        onSearchChange?()
        let pid = item.resolvedPlaylistID ?? ""
        Task { [weak self] in
            guard let self else { return }
            let songs = await self.libraryIndex.playlistPage(id: pid)
            guard self.activePlaylistPage?.id == item.id else { return }
            self.activePlaylistSongs = songs
            if let playingIndex = self.matchingSongIndex(in: songs) {
                self.playlistSelection = playingIndex
            }
            self.prefetchArtwork([item] + Array(songs.prefix(28)))
            self.onSearchChange?()
        }
    }

    func playPlaylist(_ item: SearchItem, shuffled: Bool = false) {
        if activePlaylistPage == nil, let idx = savedPlaylists.firstIndex(where: { $0.id == item.id }) {
            playlistSelection = idx
        }
        let key = "playlist:\(item.id):\(shuffled)"
        if shouldIgnoreDuplicatePlayback(key: key) { return }

        playbackRequestID &+= 1
        let requestID = playbackRequestID
        playbackTask?.cancel()
        statusMessage = nil
        currentPlayingPlaylistID = item.resolvedPlaylistID

        let previousTrack = trackID
        let cachedSongs: [SearchItem]? = if activePlaylistPage?.id == item.id, !activePlaylistSongs.isEmpty {
            activePlaylistSongs
        } else if let cached = detailCache[item.id]?.songs, !cached.isEmpty {
            cached
        } else {
            nil
        }

        let orderedInitial = shuffled ? (cachedSongs?.shuffled()) : cachedSongs
        beginOptimisticPlayback(
            primary: orderedInitial?.first,
            context: item,
            queue: orderedInitial ?? [],
            previousTrack: previousTrack
        )
        onSearchChange?()
        publishPlayback()

        playbackTask = Task { [weak self] in
            guard let self else { return }
            let baseSongs: [SearchItem]
            if let cachedSongs {
                baseSongs = cachedSongs
            } else if let pid = item.resolvedPlaylistID {
                baseSongs = await self.libraryIndex.playlistPage(id: pid)
            } else {
                baseSongs = []
            }
            guard !Task.isCancelled, self.playbackRequestID == requestID else { return }
            let queue = shuffled ? baseSongs.shuffled() : baseSongs
            guard let first = queue.first else {
                self.failPlaybackPreparation("Liste parçaları bulunamadı.", requestID: requestID)
                return
            }
            self.updateOptimisticFirstSong(first, context: item, queue: queue, previousTrack: previousTrack)
            await self.startSongQueue(queue, requestID: requestID)
        }
        scheduleRefresh(after: .milliseconds(350))
    }

    func playPlaylistSong(_ item: SearchItem) {
        if let index = activePlaylistSongs.firstIndex(where: { $0.id == item.id }) {
            playlistSelection = index
        }
        let key = "plsong:\(item.id)"
        if shouldIgnoreDuplicatePlayback(key: key) { return }

        playbackRequestID &+= 1
        let requestID = playbackRequestID
        playbackTask?.cancel()
        statusMessage = nil
        currentPlayingPlaylistID = activePlaylistPage?.resolvedPlaylistID ?? item.resolvedPlaylistID

        let previousTrack = trackID
        let queue: [SearchItem]
        if let index = activePlaylistSongs.firstIndex(where: { $0.id == item.id }) {
            queue = Array(activePlaylistSongs[index...])
        } else {
            queue = [item]
        }
        beginOptimisticPlayback(primary: item, context: activePlaylistPage ?? item, queue: queue, previousTrack: previousTrack)
        onSearchChange?()
        publishPlayback()
        playbackTask = Task { [weak self] in
            await self?.startSongQueue(queue, requestID: requestID)
        }
        scheduleRefresh(after: .milliseconds(350))
    }

    // MARK: - Search Item Playback

    func playSearchItem(_ item: SearchItem, dismissAfter: Bool) {
        if !isShowingSearchHistory, let idx = searchFocusItems.firstIndex(where: { $0.id == item.id }) {
            searchSelection = idx
        }
        if overlayMode == .search, searchStack.isEmpty {
            recordItemInHistory(item)
        }
        let key = "search:\(item.id)"
        if shouldIgnoreDuplicatePlayback(key: key) {
            if dismissAfter { collapseOverlay() }
            return
        }

        playbackRequestID &+= 1
        let requestID = playbackRequestID
        playbackTask?.cancel()
        statusMessage = nil
        currentPlayingPlaylistID = item.kind == .playlist
            ? item.resolvedPlaylistID
            : (searchStack.last?.kind == .playlist ? searchStack.last?.resolvedPlaylistID : nil)

        let previousTrack = trackID
        let pageSongs = detailSongs
        let activePageID = searchStack.last?.id
        let scope = searchScope

        switch item.kind {
        case .song:
            let queue: [SearchItem]
            if activePageID != nil, let index = pageSongs.firstIndex(where: { $0.id == item.id }) {
                queue = Array(pageSongs[index...])
            } else {
                queue = [item]
            }
            beginOptimisticPlayback(primary: item, context: item, queue: queue, previousTrack: previousTrack)
            playbackTask = Task { [weak self] in
                await self?.startSongQueue(queue, requestID: requestID)
            }

        case .album:
            let knownSongs: [SearchItem]? = if activePageID == item.id, !pageSongs.isEmpty {
                pageSongs
            } else if let cached = detailCache[item.id]?.songs, !cached.isEmpty {
                cached
            } else {
                nil
            }
            beginOptimisticPlayback(
                primary: knownSongs?.first,
                context: item,
                queue: knownSongs ?? [],
                previousTrack: previousTrack
            )
            playbackTask = Task { [weak self] in
                guard let self else { return }
                let songs: [SearchItem]
                if let knownSongs {
                    songs = knownSongs
                } else {
                    songs = await self.resolveAlbumSongs(for: item, scope: scope)
                }
                guard !Task.isCancelled, self.playbackRequestID == requestID else { return }
                guard let first = songs.first else {
                    self.failPlaybackPreparation("Albüm parçaları yüklenemedi.", requestID: requestID)
                    return
                }
                self.updateOptimisticFirstSong(first, context: item, queue: songs, previousTrack: previousTrack)
                await self.startSongQueue(songs, requestID: requestID)
            }

        case .artist:
            let knownSongs: [SearchItem]? = if activePageID == item.id, !pageSongs.isEmpty {
                pageSongs
            } else if let cached = detailCache[item.id]?.songs, !cached.isEmpty {
                cached
            } else {
                nil
            }
            beginOptimisticPlayback(
                primary: knownSongs?.first,
                context: item,
                queue: knownSongs ?? [],
                previousTrack: previousTrack
            )
            playbackTask = Task { [weak self] in
                guard let self else { return }
                let songs: [SearchItem]
                if let knownSongs {
                    songs = knownSongs
                } else {
                    songs = await self.resolveArtistSongs(for: item, scope: scope)
                }
                guard !Task.isCancelled, self.playbackRequestID == requestID else { return }
                guard let first = songs.first else {
                    self.failPlaybackPreparation("Sanatçı parçaları yüklenemedi.", requestID: requestID)
                    return
                }
                self.updateOptimisticFirstSong(first, context: item, queue: songs, previousTrack: previousTrack)
                await self.startSongQueue(songs, requestID: requestID)
            }

        case .playlist:
            let knownSongs: [SearchItem]? = if activePageID == item.id, !pageSongs.isEmpty {
                pageSongs
            } else if let cached = detailCache[item.id]?.songs, !cached.isEmpty {
                cached
            } else {
                nil
            }
            beginOptimisticPlayback(
                primary: knownSongs?.first,
                context: item,
                queue: knownSongs ?? [],
                previousTrack: previousTrack
            )
            playbackTask = Task { [weak self] in
                guard let self else { return }
                let songs: [SearchItem]
                if let knownSongs {
                    songs = knownSongs
                } else if let pid = item.resolvedPlaylistID {
                    songs = await self.libraryIndex.playlistPage(id: pid)
                } else {
                    songs = []
                }
                guard !Task.isCancelled, self.playbackRequestID == requestID else { return }
                guard let first = songs.first else {
                    self.failPlaybackPreparation("Liste parçaları bulunamadı.", requestID: requestID)
                    return
                }
                self.updateOptimisticFirstSong(first, context: item, queue: songs, previousTrack: previousTrack)
                await self.startSongQueue(songs, requestID: requestID)
            }
        }

        if dismissAfter {
            collapseOverlay()
        } else {
            onSearchChange?()
        }
        generation += 1
        onPlaybackChange?()
        scheduleRefresh(after: .milliseconds(350))
    }

    private func shouldIgnoreDuplicatePlayback(key: String) -> Bool {
        let now = Date()
        if isPreparingPlayback, key == activePlaybackKey, now.timeIntervalSince(activePlaybackStartedAt) < 2.5 {
            return true
        }
        activePlaybackKey = key
        activePlaybackStartedAt = now
        return false
    }

    private func resolveAlbumSongs(for item: SearchItem, scope: SearchScope) async -> [SearchItem] {
        let albumTitle = item.album.isEmpty ? item.title : item.album
        if item.id.hasPrefix("library-album-") || (scope == .library && item.resolvedCollectionID == nil) {
            let local = await libraryIndex.albumPage(artist: item.artist, album: albumTitle)
            if !local.isEmpty { return local }
        }
        if let remote = await CatalogSearch.albumPage(
            collectionID: item.resolvedCollectionID,
            title: albumTitle,
            artist: item.artist
        ), !remote.isEmpty {
            return remote
        }
        return await libraryIndex.albumPage(artist: item.artist, album: albumTitle)
    }

    private func resolveArtistSongs(for item: SearchItem, scope: SearchScope) async -> [SearchItem] {
        let artistName = item.artist.isEmpty ? item.title : item.artist
        if item.id.hasPrefix("library-artist-") || (scope == .library && item.resolvedArtistID == nil) {
            let local = await libraryIndex.artistPage(named: artistName).songs
            if !local.isEmpty { return local }
        }
        if let remote = await CatalogSearch.artistPage(artistID: item.resolvedArtistID, name: artistName)?.songs,
           !remote.isEmpty {
            return remote
        }
        return await libraryIndex.artistPage(named: artistName).songs
    }

    private func startSongQueue(_ songs: [SearchItem], requestID: UInt64) async {
        guard let first = songs.first, playbackRequestID == requestID, !Task.isCancelled else { return }

        // Resolve local persistentID if the track is in the user's Library or Playlists.
        var localTrack: LibraryTrack?
        if let pid = first.persistentID {
            localTrack = await libraryIndex.track(forPersistentID: pid)
                ?? LibraryTrack(
                    id: pid,
                    title: first.title,
                    artist: first.artist,
                    album: first.album,
                    duration: first.duration,
                    storeID: first.storeID,
                    trackNumber: first.trackNumber,
                    isPlaylistOnly: first.isPlaylistOnly
                )
        } else {
            localTrack = await libraryIndex.track(
                storeID: first.storeID,
                title: first.title,
                artist: first.artist,
                album: first.album
            )
        }

        let catalogIDs = await resolveStoreIDs(for: songs)
        guard !Task.isCancelled, playbackRequestID == requestID else { return }

        // For a single track (`songs.count == 1`), or when the first track is a local file with no Store ID,
        // play directly by persistentID (~0.3s startup, zero queue collision!).
        // For multi-track queues (albums, artists, playlists), prefer a single atomic `playCatalogQueue`
        // so AppleScript `play` + `insertCatalogQueue` never collide or stall playback!
        let useDirectLibraryPlay = localTrack != nil && (songs.count == 1 || catalogIDs.isEmpty)
        if useDirectLibraryPlay, let localTrack {
            let playlistHint: String? = if let explicit = first.resolvedPlaylistID {
                explicit
            } else {
                await libraryIndex.containingPlaylistID(for: localTrack.id)
            }
            let started = await PlayerScript.playLibraryTrack(
                persistentID: localTrack.id,
                playlistID: playlistHint,
                isPlaylistOnly: localTrack.isPlaylistOnly
            )
            guard !Task.isCancelled, playbackRequestID == requestID else { return }
            if started {
                scheduleRefresh(after: .milliseconds(100))
                return
            }
        }

        guard !catalogIDs.isEmpty else {
            if let localTrack {
                let playlistHint = await libraryIndex.containingPlaylistID(for: localTrack.id)
                let started = await PlayerScript.playLibraryTrack(
                    persistentID: localTrack.id,
                    playlistID: playlistHint,
                    isPlaylistOnly: localTrack.isPlaylistOnly
                )
                guard !Task.isCancelled, playbackRequestID == requestID else { return }
                if started {
                    scheduleRefresh(after: .milliseconds(100))
                    return
                }
            }
            failPlaybackPreparation("Parça başlatılamadı.", requestID: requestID)
            return
        }

        let started = await PlayerScript.playCatalogQueue(storeIDs: catalogIDs)
        guard !Task.isCancelled, playbackRequestID == requestID else { return }
        if started {
            scheduleRefresh(after: .milliseconds(100))
            // If a playlist has more than 50 tracks, wait until playback is well underway (10s)
            // before quietly appending the next chunk to the tail of Up Next.
            if catalogIDs.count > 50 {
                let remaining = Array(catalogIDs.dropFirst(50).prefix(120))
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, playbackRequestID == requestID, clock.isPlaying {
                    await PlayerScript.enqueueUpNext(storeIDs: remaining)
                }
            }
        } else {
            failPlaybackPreparation("Apple Music parçayı başlatamadı.", requestID: requestID)
        }
    }

    private func resolveStoreIDs(for items: [SearchItem]) async -> [Int] {
        var ids: [Int] = []
        ids.reserveCapacity(items.count)
        for item in items {
            if let sid = item.storeID, sid > 0 {
                ids.append(sid)
            } else if let pid = item.persistentID, let track = await libraryIndex.track(forPersistentID: pid), let sid = track.storeID, sid > 0 {
                ids.append(sid)
            } else if let track = await libraryIndex.track(storeID: nil, title: item.title, artist: item.artist, album: item.album), let sid = track.storeID, sid > 0 {
                ids.append(sid)
            }
        }
        return ids
    }

    private func failPlaybackPreparation(_ message: String, requestID: UInt64) {
        guard playbackRequestID == requestID else { return }
        isPreparingPlayback = false
        catalogWait = nil
        transportIntent = nil
        statusMessage = message
        subtitle = message
        syncIdleWallpaper()
        publishPlayback()
        onSearchChange?()
    }

    func openMusicForSearch() {
        Task { [weak self] in
            _ = await PlayerScript.ensureMusicRunningHidden()
            try? await Task.sleep(for: .milliseconds(400))
            self?.refreshLibraryIfNeeded(force: true)
        }
    }

    func nudge(by delta: TimeInterval) {
        seek(to: clock.elapsed(at: .now) + delta)
    }

    private func shouldRouteTransportToColdMusic(for action: TransportAction) -> Bool {
        if case .pause = action { return false }
        if PlayerScript.isRunning(.music) { return false }
        if playbackSource == PlayerKind.spotify.sourceID, PlayerScript.isRunning(.spotify) { return false }
        if playbackSource == "system" {
            if !title.isEmpty { return false }
            if PlayerScript.isRunning(.spotify) { return false }
        }
        return true
    }

    private func performColdMusicTransport(_ action: TransportAction) {
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        playbackTask?.cancel()
        confirmTask?.cancel()
        statusMessage = nil

        let resumeTitle = title
        let resumeArtist = artist
        let resumeAlbum = album
        let resumeStoreID = currentStoreID
        let resumeElapsed = clock.elapsed(at: .now)
        let previousTrack = trackID

        isPreparingPlayback = true
        playbackSource = PlayerKind.music.sourceID
        sourceName = PlayerKind.music.displayName
        pinNewPlayback(replacing: previousTrack)
        publishPlayback()

        playbackTask = Task { [weak self] in
            guard let self else { return }
            if self.playbackSource != PlayerKind.music.sourceID || !resumeTitle.isEmpty {
                let activeBundle = await self.nowPlaying.activeBundleIdentifier()
                if let activeBundle, activeBundle != "com.apple.Music", activeBundle != "com.spotify.client", !resumeTitle.isEmpty {
                    guard !Task.isCancelled, self.playbackRequestID == requestID else { return }
                    self.isPreparingPlayback = false
                    let position: Double? = if case .seek(let seconds) = action { seconds } else { nil }
                    self.nowPlaying.send(action.mediaCommand, position: position)
                    self.refreshNow()
                    return
                }
            }

            var started = false
            if !resumeTitle.isEmpty {
                // Music's startup session restoration preserves the exact track, position, and Up Next queue
                // from before Music quit — resume it directly in a single step whenever it matches!
                started = await PlayerScript.launchAndPerformTransport(action, matchingTitle: resumeTitle)
            }

            let wantsTrackResume: Bool = switch action {
            case .play, .seek: !resumeTitle.isEmpty
            case .pause, .next, .previous: false
            }

            if !started, wantsTrackResume {
                let localTrack = await self.libraryIndex.track(
                    storeID: resumeStoreID,
                    title: resumeTitle,
                    artist: resumeArtist,
                    album: resumeAlbum
                )
                if let localTrack {
                    let playlistHint = await self.libraryIndex.containingPlaylistID(for: localTrack.id)
                    started = await PlayerScript.playLibraryTrack(
                        persistentID: localTrack.id,
                        playlistID: playlistHint,
                        isPlaylistOnly: localTrack.isPlaylistOnly
                    )
                }
                if !started, let sid = resumeStoreID ?? localTrack?.storeID, sid > 0 {
                    started = await PlayerScript.playCatalogQueue(storeIDs: [sid])
                }
                if started, case .seek(let seconds) = action, seconds > 0.5 {
                    PlayerScript.send(.seek(seconds), to: .music)
                } else if started, case .play = action, resumeElapsed > 3 {
                    PlayerScript.send(.seek(resumeElapsed), to: .music)
                }
            }

            if !started {
                started = await PlayerScript.launchAndPerformTransport(action)
            }
            guard !Task.isCancelled, self.playbackRequestID == requestID else { return }
            if started {
                self.refreshNow()
                self.scheduleSettleRefresh(after: .milliseconds(350))
            } else {
                self.failPlaybackPreparation("Apple Music başlatılamadı.", requestID: requestID)
            }
        }
    }

    private func send(_ action: TransportAction) {
        noteTransport(action)
        let position: Double? = if case .seek(let seconds) = action { seconds } else { nil }
        guard let kind = transportTarget() else {
            nowPlaying.send(action.mediaCommand, position: position)
            return
        }
        let targetBundle = kind == .music ? "com.apple.Music" : "com.spotify.client"
        Task { [nowPlaying] in
            let activeBundle = await nowPlaying.activeBundleIdentifier()
            if activeBundle == targetBundle {
                nowPlaying.send(action.mediaCommand, position: position)
            } else {
                PlayerScript.send(action, to: kind)
            }
        }
    }

    /// Music and Spotify answer Apple events directly. A browser or other player stays on MediaRemote.
    private func transportTarget() -> PlayerKind? {
        switch playbackSource {
        case PlayerKind.music.sourceID:
            return .music
        case PlayerKind.spotify.sourceID:
            return .spotify
        default:
            guard title.isEmpty else { return nil }
            if PlayerScript.isRunning(.music) { return .music }
            if PlayerScript.isRunning(.spotify) { return .spotify }
            return nil
        }
    }

    private func noteTransport(_ action: TransportAction) {
        commandIssuedAt = Date()
        catalogWait = nil
        switch action {
        case .play:
            transportHold = 0.55
            transportIntent = TransportIntent(rate: 1, rejectTrackID: nil, elapsed: clock.elapsed(at: .now), pinElapsed: false)
        case .pause:
            transportHold = 0.55
            transportIntent = TransportIntent(rate: 0, rejectTrackID: nil, elapsed: clock.elapsed(at: .now), pinElapsed: true)
        case .next, .previous:
            transportHold = 1.5
            transportIntent = TransportIntent(rate: nil, rejectTrackID: trackID, elapsed: clock.elapsed(at: .now), pinElapsed: false)
        case .seek(let seconds):
            transportHold = 1.2
            transportIntent = TransportIntent(rate: nil, rejectTrackID: nil, elapsed: seconds, pinElapsed: true)
        }
    }

    private func publishPlayback() {
        generation += 1
        onPlaybackChange?()
    }

    private func scheduleTransportConfirmation() {
        scheduleRefresh(after: .milliseconds(90))
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func restoreOriginalWallpaper() {
        renderTask?.cancel()
        upgradeTask?.cancel()
        wallpaper.restoreOriginals()
        statusMessage = nil
    }

    func reapplyArtwork() {
        wallpaper.invalidate()
        scheduleRender()
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "Açılışta başlatmak için Coverdesk’i Uygulamalar klasörüne taşı, sonra Sistem Ayarları’ndan onayla."
        }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Sistem Ayarları → Genel → Giriş Öğeleri ve Uzantılar bölümünden Coverdesk’e izin ver."
        }
        return nil
    }

    private func refreshLibraryIfNeeded(force: Bool) {
        if !force, let libraryFetchedAt, libraryCount > 0, Date().timeIntervalSince(libraryFetchedAt) < 180 {
            return
        }
        if !force, libraryCount == 0, let libraryFailedAt, Date().timeIntervalSince(libraryFailedAt) < 6 {
            return
        }
        if libraryTask != nil {
            if force { libraryRefreshAgain = true }
            return
        }
        libraryTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLibrary(force: force)
            self.libraryTask = nil
            if self.libraryRefreshAgain {
                self.libraryRefreshAgain = false
                self.refreshLibraryIfNeeded(force: true)
            }
        }
    }

    private func loadLibrary(force: Bool) async {
        var hasTracks = await libraryIndex.count > 0
        if !hasTracks, let cached = await LibraryDiskCache.load() {
            await libraryIndex.replace(cached.tracks, playlists: cached.playlists, fetchedAt: cached.fetchedAt)
            libraryFetchedAt = cached.fetchedAt
            libraryCount = cached.tracks.count + cached.playlists.count
            savedPlaylists = await libraryIndex.allPlaylists()
            hasTracks = libraryCount > 0
            libraryStatus = hasTracks ? .ready : .loading
            if isPlaylistsPresented {
                prefetchArtwork(savedPlaylists)
            }
            refilterSearch()
            onSearchChange?()
        }
        if !force, let libraryFetchedAt, hasTracks, Date().timeIntervalSince(libraryFetchedAt) < 180 {
            if savedPlaylists.isEmpty {
                savedPlaylists = await libraryIndex.allPlaylists()
            }
            libraryStatus = .ready
            onSearchChange?()
            return
        }
        if !hasTracks {
            libraryStatus = .loading
            onSearchChange?()
        }
        let result = await LibraryCatalog.fetchLibrary()
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let payload):
            let now = Date()
            await libraryIndex.replace(payload.tracks, playlists: payload.playlists, fetchedAt: now)
            libraryFetchedAt = now
            libraryFailedAt = nil
            libraryCount = payload.tracks.count + payload.playlists.count
            savedPlaylists = await libraryIndex.allPlaylists()
            if let openPage = activePlaylistPage, let pid = openPage.resolvedPlaylistID {
                activePlaylistSongs = await libraryIndex.playlistPage(id: pid)
                if let updated = savedPlaylists.first(where: { $0.id == openPage.id }) {
                    activePlaylistPage = updated
                }
            }
            libraryStatus = .ready
            if isPlaylistsPresented {
                prefetchArtwork(savedPlaylists + Array(activePlaylistSongs.prefix(24)))
            }
            refilterSearch()
            await LibraryDiskCache.save(payload.tracks, playlists: payload.playlists, fetchedAt: now)
        case .failure(let block):
            libraryFailedAt = .now
            if !hasTracks {
                libraryStatus = .unavailable(block)
            }
        }
        onSearchChange?()
    }

    private func resetSearchNavigation() {
        searchStack = []
        detailSongs = []
        detailAlbums = []
        detailState = .idle
        detailGeneration += 1
    }

    private func showDetail(_ item: SearchItem) {
        if let cached = detailCache[item.id] {
            detailSongs = cached.songs
            detailAlbums = cached.albums
            detailState = .idle
            syncOverlaySelectionToCurrentTrack()
            prefetchArtwork([item] + cached.songs + cached.albums)
            onSearchChange?()
            return
        }
        let seeded = seededDetail(for: item)
        detailSongs = seeded.songs
        detailAlbums = seeded.albums
        detailState = seeded.songs.isEmpty && seeded.albums.isEmpty ? .loading : .idle
        syncOverlaySelectionToCurrentTrack()
        prefetchArtwork([item] + seeded.songs + seeded.albums)
        onSearchChange?()
        detailGeneration += 1
        let generation = detailGeneration
        let scope = searchScope
        Task { [weak self] in
            guard let self else { return }
            switch (scope, item.kind) {
            case (_, .playlist):
                let songs = await self.libraryIndex.playlistPage(id: item.resolvedPlaylistID ?? "")
                self.applyDetail(songs, [], id: item.id, generation: generation, failed: songs.isEmpty)
            case (.library, .artist):
                let page = await self.libraryIndex.artistPage(named: item.artist)
                let songs = page.songs.isEmpty ? seeded.songs : page.songs
                let albums = page.albums.isEmpty ? seeded.albums : page.albums
                self.applyDetail(songs, albums, id: item.id, generation: generation, failed: false)
            case (.library, .album):
                let songs = await self.libraryIndex.albumPage(artist: item.artist, album: item.album)
                let resolved = songs.isEmpty ? seeded.songs : songs
                self.applyDetail(resolved, [], id: item.id, generation: generation, failed: false)
            case (.appleMusic, .artist):
                if let page = await CatalogSearch.artistPage(artistID: item.resolvedArtistID, name: item.artist) {
                    let songs = page.songs.isEmpty ? seeded.songs : page.songs
                    let albums = page.albums.isEmpty ? seeded.albums : page.albums
                    self.applyDetail(songs, albums, id: item.id, generation: generation, failed: songs.isEmpty && albums.isEmpty)
                } else {
                    self.applyDetail(seeded.songs, seeded.albums, id: item.id, generation: generation, failed: seeded.songs.isEmpty && seeded.albums.isEmpty)
                }
            case (.appleMusic, .album):
                if let songs = await CatalogSearch.albumPage(
                    collectionID: item.resolvedCollectionID,
                    title: item.album.isEmpty ? item.title : item.album,
                    artist: item.artist
                ) {
                    let resolved = songs.isEmpty ? seeded.songs : songs
                    self.applyDetail(resolved, [], id: item.id, generation: generation, failed: resolved.isEmpty)
                } else {
                    self.applyDetail(seeded.songs, [], id: item.id, generation: generation, failed: seeded.songs.isEmpty)
                }
            default:
                break
            }
        }
    }

    private func seededDetail(for item: SearchItem) -> (songs: [SearchItem], albums: [SearchItem]) {
        switch item.kind {
        case .artist:
            let songs = searchResults.filter { $0.kind == .song && SearchItem.looseMatch($0.artist, item.artist) }
            let albums = searchResults.filter { $0.kind == .album && SearchItem.looseMatch($0.artist, item.artist) }
            return (songs, albums)
        case .album:
            let songs = searchResults.filter { song in
                song.kind == .song
                    && SearchItem.looseMatch(song.album, item.album.isEmpty ? item.title : item.album)
                    && (item.artist.isEmpty || SearchItem.looseMatch(song.artist, item.artist))
            }
            return (songs, [])
        case .playlist, .song:
            return ([], [])
        }
    }

    private func applyDetail(
        _ songs: [SearchItem],
        _ albums: [SearchItem],
        id: String,
        generation: Int,
        failed: Bool
    ) {
        guard generation == detailGeneration else { return }
        detailSongs = songs
        detailAlbums = albums
        detailState = failed ? .failed : .idle
        syncOverlaySelectionToCurrentTrack()
        if !failed {
            detailCache[id] = (songs, albums)
            if detailCache.count > 12 {
                detailCache.removeAll()
                detailCache[id] = (songs, albums)
            }
        }
        if let page = searchStack.last {
            prefetchArtwork([page] + songs + albums)
        }
        onSearchChange?()
    }

    func isCurrentItem(_ item: SearchItem) -> Bool {
        if item.kind == .playlist {
            guard !title.isEmpty, let pid = item.resolvedPlaylistID else { return false }
            return currentPlayingPlaylistID == pid
        }
        guard item.kind == .song, !title.isEmpty else { return false }
        let contextSongs: [SearchItem] = switch overlayMode {
        case .playlists:
            activePlaylistSongs
        case .search:
            searchStack.isEmpty ? searchResults : detailSongs
        case .none:
            []
        }
        if let matchedIndex = matchingSongIndex(in: contextSongs), contextSongs.indices.contains(matchedIndex) {
            let winner = contextSongs[matchedIndex]
            if contextSongs.contains(where: { $0.id == item.id }) {
                return winner.id == item.id
            }
        }
        if let sid = item.storeID, sid > 0, let activeSID = currentStoreID, activeSID > 0 {
            if sid == activeSID { return true }
            return SearchItem.sameName(title, item.title)
                && (item.artist.isEmpty || artist.isEmpty || SearchItem.sameName(artist, item.artist))
        }
        return SearchItem.looseMatch(title, item.title)
            && (item.artist.isEmpty || SearchItem.looseMatch(artist, item.artist))
    }

    private func matchingSongIndex(in items: [SearchItem]) -> Int? {
        guard !title.isEmpty, !items.isEmpty else { return nil }
        if let activeSID = currentStoreID, activeSID > 0,
           let exactSID = items.firstIndex(where: { $0.kind == .song && $0.storeID == activeSID }) {
            return exactSID
        }
        if let exactTitle = items.firstIndex(where: {
            $0.kind == .song
                && SearchItem.sameName($0.title, title)
                && ($0.artist.isEmpty || artist.isEmpty || SearchItem.sameName($0.artist, artist))
                && ($0.album.isEmpty || album.isEmpty || SearchItem.looseMatch($0.album, album))
        }) {
            return exactTitle
        }
        if let exactTitleOnly = items.firstIndex(where: {
            $0.kind == .song
                && SearchItem.sameName($0.title, title)
                && ($0.artist.isEmpty || artist.isEmpty || SearchItem.looseMatch($0.artist, artist))
        }) {
            return exactTitleOnly
        }
        return items.firstIndex(where: {
            $0.kind == .song
                && SearchItem.looseMatch($0.title, title)
                && ($0.artist.isEmpty || artist.isEmpty || SearchItem.looseMatch($0.artist, artist))
        })
    }

    private func syncOverlaySelectionToCurrentTrack() {
        if !searchStack.isEmpty {
            let items = searchFocusItems
            if let index = matchingSongIndex(in: items) {
                searchSelection = index
            }
        }
        if activePlaylistPage != nil {
            if let index = matchingSongIndex(in: activePlaylistSongs) {
                playlistSelection = index
            }
        }
    }

    private func beginOptimisticPlayback(
        primary: SearchItem?,
        context: SearchItem,
        queue: [SearchItem],
        previousTrack: String
    ) {
        isPreparingPlayback = true
        let coldStart = !PlayerScript.isRunning(.music)
        let target = primary ?? context
        adoptContext(
            title: target.title,
            artist: target.artist,
            album: target.kind == .album ? target.title : target.album,
            subtitle: primary?.subtitle ?? context.subtitle,
            duration: primary?.duration ?? 0,
            storeID: primary?.storeID
        )
        syncOverlaySelectionToCurrentTrack()
        pinNewPlayback(replacing: previousTrack)
        let storeIDs = Set(([primary?.storeID] + queue.map(\.storeID)).compactMap { $0 }.filter { $0 > 0 })
        catalogWait = CatalogWait(
            until: Date().addingTimeInterval(coldStart ? 18 : 10),
            kind: primary != nil ? .song : context.kind,
            title: target.title,
            artist: target.artist,
            album: target.kind == .album ? target.title : target.album,
            storeIDs: storeIDs,
            collectionID: context.resolvedCollectionID ?? primary?.resolvedCollectionID,
            artistID: context.resolvedArtistID ?? primary?.resolvedArtistID,
            previousTrackID: previousTrack
        )
        if primary != nil {
            loadLyricsIfNeeded()
        }
        prewarmSelectedArtwork(primary ?? context, fallback: context)
    }

    private func updateOptimisticFirstSong(
        _ first: SearchItem,
        context: SearchItem,
        queue: [SearchItem],
        previousTrack: String
    ) {
        let coldStart = !PlayerScript.isRunning(.music)
        adoptContext(
            title: first.title,
            artist: first.artist,
            album: first.album,
            subtitle: first.subtitle,
            duration: first.duration,
            storeID: first.storeID
        )
        syncOverlaySelectionToCurrentTrack()
        pinNewPlayback(replacing: previousTrack)
        let storeIDs = Set(queue.compactMap(\.storeID).filter { $0 > 0 })
        catalogWait = CatalogWait(
            until: Date().addingTimeInterval(coldStart ? 18 : 10),
            kind: .song,
            title: first.title,
            artist: first.artist,
            album: first.album,
            storeIDs: storeIDs,
            collectionID: context.resolvedCollectionID ?? first.resolvedCollectionID,
            artistID: context.resolvedArtistID ?? first.resolvedArtistID,
            previousTrackID: previousTrack
        )
        loadLyricsIfNeeded()
        prewarmSelectedArtwork(first, fallback: context)
        publishPlayback()
        onSearchChange?()
    }

    /// Starts rendering the selected item's cover onto the desktop immediately without waiting for stream buffering.
    private func prewarmSelectedArtwork(_ item: SearchItem, fallback: SearchItem) {
        optimisticArtTask?.cancel()
        let requestID = playbackRequestID
        let artURL = item.artworkURL ?? fallback.artworkURL
        let libID = item.libraryArtID ?? fallback.libraryArtID
        let artIdentity = artURL?.absoluteString ?? "optimistic:\(item.artworkKey)"
        guard artIdentity != currentArtworkIdentity else { return }

        optimisticArtTask = Task { [weak self] in
            var data: Data?
            if let artURL {
                if let hiRes = ArtworkURL.highResolutionURL(from: artURL.absoluteString),
                   let sharp = await CatalogSearch.artworkData(from: hiRes) {
                    data = sharp
                } else {
                    data = await CatalogSearch.artworkData(from: artURL)
                }
            }
            if data == nil, let libID {
                data = await LibraryCatalog.artworkData(id: libID)
            }
            guard !Task.isCancelled, let self, self.playbackRequestID == requestID, let data, !data.isEmpty else {
                return
            }
            guard self.currentArtworkIdentity != artIdentity else { return }
            self.currentArtworkIdentity = artIdentity
            self.artworkToken = "\(artIdentity)#\(data.count)"
            self.latestArtwork = data
            self.hasArtwork = true
            self.artwork = Self.thumbnail(from: data)
            self.scheduleRender()
            self.publishPlayback()
        }
    }

    private func pinNewPlayback(replacing previousTrack: String) {
        commandIssuedAt = Date()
        transportHold = PlayerScript.isRunning(.music) ? 9 : 15
        let reject = (previousTrack.isEmpty || previousTrack == trackID) ? nil : previousTrack
        transportIntent = TransportIntent(
            rate: nil,
            rejectTrackID: reject,
            elapsed: 0,
            pinElapsed: false
        )
        scheduleTransportConfirmation()
    }

    private func adoptContext(
        title: String,
        artist: String,
        album: String,
        subtitle: String,
        duration: TimeInterval,
        storeID: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.subtitle = subtitle
        self.currentStoreID = storeID
        let nextID = [title, artist, album].joined(separator: "\u{1f}")
        if nextID != trackID {
            loadedLyricsTrack = ""
            lyrics = .empty
            lyricsResolved = false
        }
        trackID = nextID
        playbackSource = PlayerKind.music.sourceID
        sourceName = PlayerKind.music.displayName
        clock = PlaybackClock(anchorElapsed: 0, anchorDate: .now, rate: 0, duration: duration)
        hasClock = duration > 1
    }

    private func refilterSearch() {
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchQuery
        let scope = searchScope
        Task { [weak self] in
            guard let self else { return }
            switch scope {
            case .library:
                let results = await self.libraryIndex.listing(for: query)
                guard generation == self.searchGeneration else { return }
                self.applySearchResults(results)
            case .appleMusic:
                try? await Task.sleep(for: .milliseconds(160))
                guard generation == self.searchGeneration else { return }
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.searchResults = []
                    self.settledSearchQuery = ""
                    self.catalogState = .idle
                    self.onSearchChange?()
                    return
                }
                self.catalogState = .loading
                if self.searchResults.isEmpty { self.onSearchChange?() }
                let listing = await CatalogSearch.listing(matching: trimmed)
                guard generation == self.searchGeneration else { return }
                if let listing {
                    self.catalogState = .idle
                    self.applySearchResults(listing)
                } else {
                    self.catalogState = .failed
                    self.settledSearchQuery = trimmed
                    if self.searchResults.isEmpty { self.onSearchChange?() }
                }
            }
        }
    }

    private func applySearchResults(_ results: [SearchItem]) {
        let sameIDs = results.map(\.id) == searchResults.map(\.id)
        settledSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = results
        if searchStack.isEmpty, !sameIDs || !results.indices.contains(searchSelection) {
            searchSelection = 0
        }
        prefetchArtwork(results)
        onSearchChange?()
    }

    func ensureArtwork(for item: SearchItem) {
        let key = item.artworkKey
        guard !key.isEmpty, searchArtwork[key] == nil, !artworkMisses.contains(key) else { return }
        guard !artworkQueue.contains(where: { $0.key == key }) else { return }
        artworkQueue.append(makeArtJob(for: item))
        if artworkQueue.count > 48 {
            artworkQueue.removeFirst(artworkQueue.count - 48)
        }
        if artworkTask == nil {
            artworkTask = Task { [weak self] in
                await self?.drainArtwork()
            }
        }
    }

    private func prefetchArtwork(_ items: [SearchItem]) {
        var jobs: [SearchArtJob] = []
        var seen: Set<String> = []
        for item in items.prefix(36) {
            let key = item.artworkKey
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard searchArtwork[key] == nil, !artworkMisses.contains(key) else { continue }
            jobs.append(makeArtJob(for: item))
        }
        guard !jobs.isEmpty else { return }
        artworkQueue = jobs
        guard artworkTask == nil else { return }
        artworkTask = Task { [weak self] in
            await self?.drainArtwork()
        }
    }

    private func makeArtJob(for item: SearchItem) -> SearchArtJob {
        SearchArtJob(
            key: item.artworkKey,
            url: item.artworkURL,
            artist: item.artist,
            album: item.album,
            title: item.kind == .song ? item.title : "",
            libraryID: item.libraryArtID,
            playlistID: item.kind == .playlist ? item.resolvedPlaylistID : nil,
            artistID: item.artistID
        )
    }

    private func drainArtwork() async {
        while !artworkQueue.isEmpty {
            if Task.isCancelled { break }
            let count = min(4, artworkQueue.count)
            let batch = Array(artworkQueue.prefix(count))
            artworkQueue.removeFirst(count)
            let loaded = await withTaskGroup(of: (String, Data)?.self) { group in
                for job in batch where searchArtwork[job.key] == nil && !artworkMisses.contains(job.key) {
                    group.addTask {
                        guard let data = await SearchArtLoader.data(for: job) else { return nil }
                        return (job.key, data)
                    }
                }
                var images: [(String, Data)] = []
                for await image in group {
                    if let image { images.append(image) }
                }
                return images
            }
            let found = Set(loaded.map(\.0))
            for job in batch where searchArtwork[job.key] == nil && !found.contains(job.key) {
                artworkMisses.insert(job.key)
            }
            var changed = false
            for (key, data) in loaded {
                guard let image = Self.thumbnail(from: data) else {
                    artworkMisses.insert(key)
                    continue
                }
                storeArtwork(image, key: key)
                changed = true
            }
            if changed { onSearchChange?() }
        }
        artworkTask = nil
        if !artworkQueue.isEmpty {
            artworkTask = Task { [weak self] in
                await self?.drainArtwork()
            }
        }
    }

    private func storeArtwork(_ image: NSImage, key: String) {
        var copy = searchArtwork
        copy[key] = image
        if copy.count > 160 {
            let visible = Set(
                (searchResults + searchStack + detailSongs + detailAlbums + savedPlaylists + activePlaylistSongs)
                    .map(\.artworkKey)
            )
            let spare = copy.keys.filter { $0 != key && !visible.contains($0) }
            for item in spare.prefix(copy.count - 160) {
                copy.removeValue(forKey: item)
            }
        }
        searchArtwork = copy
    }

    private func handleImmediateHint(_ hint: ImmediatePlaybackHint) {
        if let wait = catalogWait {
            guard let hintTitle = hint.title, !hintTitle.isEmpty else { return }
            let candidateID = [hintTitle, hint.artist ?? "", hint.album ?? ""].joined(separator: "\u{1f}")
            if !wait.previousTrackID.isEmpty, candidateID == wait.previousTrackID {
                return
            }
            let matchesExpected = SearchItem.looseMatch(hintTitle, wait.title)
                || (!wait.album.isEmpty && SearchItem.looseMatch(hint.album ?? "", wait.album))
            guard matchesExpected else { return }
            if hint.isPlaying == true {
                catalogWait = nil
                transportIntent = nil
                isPreparingPlayback = false
            }
        }

        if let hintSource = hint.source {
            if hintSource != playbackSource {
                guard hint.isPlaying == true || title.isEmpty else { return }
            }
        } else if playbackSource == PlayerKind.music.sourceID || playbackSource == PlayerKind.spotify.sourceID {
            // Music and Spotify emit dedicated `playerInfo` / `PlaybackStateChanged` notifications;
            // ignore generic MediaRemote `isPlaying` flips that may come from a background browser tab.
            return
        }

        if let intent = transportIntent, let intentRate = intent.rate, let isPlaying = hint.isPlaying {
            let matchesIntent = (intentRate > 0.5) == isPlaying
            if matchesIntent {
                if intent.rejectTrackID == nil && !intent.pinElapsed {
                    transportIntent = nil
                } else {
                    transportIntent?.rate = nil
                }
            } else if Date().timeIntervalSince(commandIssuedAt) < 0.45 {
                return
            } else {
                transportIntent = nil
            }
        }

        if hint.isStopped, !isPreparingPlayback {
            if hint.source == nil || hint.source == playbackSource {
                notePlaybackStopped()
            }
            return
        }

        if let isPlaying = hint.isPlaying {
            let now = Date()
            let targetRate: Double = isPlaying ? 1.0 : 0.0
            let currentElapsed = hint.elapsed ?? clock.elapsed(at: now)
            let clampedElapsed = clock.duration > 1 ? min(max(0, currentElapsed), clock.duration) : max(0, currentElapsed)
            if abs(clock.rate - targetRate) > 0.01 || hint.elapsed != nil {
                clock.anchorElapsed = clampedElapsed
                clock.anchorDate = now
                clock.rate = targetRate
                if isPlaying {
                    isPreparingPlayback = false
                }
                syncIdleWallpaper()
                publishPlayback()
            }
        }
    }

    private func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func scheduleSettleRefresh(after delay: Duration) {
        settleRefreshTask?.cancel()
        settleRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func scheduleRefresh(after delay: Duration = .milliseconds(160)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        let started = Date()
        defer {
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await self.refresh() }
            }
        }
        guard let snapshot = await readPlayback() else { return }
        guard started >= commandIssuedAt else { return }
        guard let accepted = acceptedTransport(snapshot) else { return }
        apply(stoppedIfPlayerQuit(accepted))
    }

    private func withLiveTiming(_ snapshot: NowPlayingSnapshot) async -> NowPlayingSnapshot {
        let kind: PlayerKind? = if snapshot.isMusicApp || snapshot.source == PlayerKind.music.sourceID {
            .music
        } else if snapshot.source == PlayerKind.spotify.sourceID {
            .spotify
        } else {
            nil
        }
        guard let kind, PlayerScript.isRunning(kind), let timing = await PlayerScript.liveTiming(for: kind) else {
            return snapshot
        }
        var updated = snapshot
        if timing.isStopped {
            if snapshot.rate <= 0.05 {
                updated.rate = 0
                updated.infoRate = 0
            }
            return updated
        }
        guard timing.trackTitle.isEmpty || SearchItem.looseMatch(timing.trackTitle, snapshot.title) else {
            return snapshot
        }
        let liveRate: Double = timing.isPlaying ? 1.0 : 0.0
        if let elapsed = timing.elapsed {
            updated.elapsed = elapsed
            updated.timestamp = timing.timestamp
        } else {
            let now = Date()
            updated.elapsed = snapshot.clock(at: now).anchorElapsed
            updated.timestamp = now
        }
        updated.rate = liveRate
        updated.infoRate = liveRate
        return updated
    }

    private func musicSnapshot() async -> NowPlayingSnapshot? {
        if let remote = await nowPlaying.snapshot(),
           (remote.source == PlayerKind.music.sourceID || remote.isMusicApp),
           !remote.title.isEmpty {
            return await withLiveTiming(remote)
        }
        let scripted = await PlayerScript.preferredSnapshot()
        guard let snapshot = scripted.snapshot, (snapshot.source == PlayerKind.music.sourceID || snapshot.isMusicApp) else {
            return nil
        }
        return await withLiveTiming(snapshot)
    }

    private func catalogSnapshotMatches(_ snapshot: NowPlayingSnapshot, wait: CatalogWait) -> Bool {
        if let sid = snapshot.storeID, wait.storeIDs.contains(sid) {
            return true
        }
        if let cid = wait.collectionID, snapshot.albumStoreID == cid {
            return true
        }
        if let aid = wait.artistID, snapshot.artistStoreID == aid {
            return true
        }
        switch wait.kind {
        case .song:
            if SearchItem.looseMatch(snapshot.title, wait.title) { return true }
            if !wait.album.isEmpty, SearchItem.looseMatch(snapshot.album, wait.album) { return true }
        case .album:
            let albumName = wait.album.isEmpty ? wait.title : wait.album
            if SearchItem.looseMatch(snapshot.album, albumName) { return true }
        case .artist:
            let artistName = wait.artist.isEmpty ? wait.title : wait.artist
            if SearchItem.looseMatch(snapshot.artist, artistName) { return true }
        case .playlist:
            if SearchItem.looseMatch(snapshot.title, wait.title) { return true }
        }
        if !snapshot.title.isEmpty,
           !wait.previousTrackID.isEmpty,
           snapshot.trackID != wait.previousTrackID,
           snapshot.rate > 0.05 {
            return true
        }
        return false
    }

    private func readPlayback() async -> NowPlayingSnapshot? {
        if let wait = catalogWait {
            if wait.until <= Date() {
                catalogWait = nil
                isPreparingPlayback = false
            } else if let snapshot = await musicSnapshot(), catalogSnapshotMatches(snapshot, wait: wait) {
                if snapshot.rate > 0.05 || snapshot.elapsed > 0.05 {
                    catalogWait = nil
                    transportIntent = nil
                    isPreparingPlayback = false
                }
                return snapshot
            } else {
                return nil
            }
        }
        if let remote = await nowPlaying.snapshot(), remote.hasDisplayableArtwork || remote.isMusicApp && !remote.title.isEmpty {
            return await withLiveTiming(remote)
        }
        let scripted = await PlayerScript.preferredSnapshot()
        if let snapshot = scripted.snapshot {
            return await withLiveTiming(snapshot)
        }
        if sourcePlayerQuit {
            notePlaybackStopped()
            return nil
        }
        if scripted.needsAutomation {
            isPreparingPlayback = false
            statusMessage = "Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon bölümünden Coverdesk’in Müzik’i denetlemesine izin ver."
            subtitle = "Otomasyon izni gerekli"
            publishPlayback()
            return nil
        }
        if let remote = await nowPlaying.snapshot(), !remote.title.isEmpty {
            return await withLiveTiming(remote)
        }
        emptyReads += 1
        if emptyReads >= 2 {
            notePlaybackStopped()
        }
        return nil
    }

    /// A read that started before the click, or one that has not caught up yet, must not undo the button.
    private func acceptedTransport(_ snapshot: NowPlayingSnapshot) -> NowPlayingSnapshot? {
        guard let intent = transportIntent else { return snapshot }
        if Date().timeIntervalSince(commandIssuedAt) >= transportHold {
            transportIntent = nil
            return snapshot
        }
        if let reject = intent.rejectTrackID, snapshot.trackID == reject {
            let restarted = snapshot.elapsed + 2 < intent.elapsed
            guard restarted else { return nil }
        }
        var held = snapshot
        var waiting = false
        if let rate = intent.rate, abs(snapshot.rate - rate) > 0.05 {
            let now = Date()
            held.elapsed = snapshot.clock(at: now).anchorElapsed
            held.timestamp = now
            held.rate = rate
            held.infoRate = rate
            waiting = true
        }
        if intent.pinElapsed, abs(held.elapsed - intent.elapsed) > 1.5 {
            held.elapsed = intent.elapsed
            held.timestamp = .now
            held.infoRate = held.rate
            waiting = true
        }
        if !waiting {
            transportIntent = nil
        }
        return held
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        let hadTrack = !title.isEmpty
        let trackChanged = snapshot.trackID != trackID
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        currentStoreID = snapshot.storeID ?? (trackChanged ? nil : currentStoreID)
        playbackSource = snapshot.source
        sourceName = snapshot.sourceName ?? ""
        subtitle = Self.subtitle(for: snapshot)
        trackID = snapshot.trackID
        if snapshot.rate > 0.05 {
            isPreparingPlayback = false
        }
        adoptClock(snapshot.clock())
        if trackChanged {
            loadedLyricsTrack = ""
            lyrics = .empty
            lyricsResolved = false
            syncOverlaySelectionToCurrentTrack()
        }
        loadLyricsIfNeeded()

        if let artwork = snapshot.artwork, !artwork.isEmpty {
            let identity = snapshot.artworkIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.trackID
            if identity != currentArtworkIdentity {
                currentArtworkIdentity = identity
                artworkToken = snapshot.artworkToken
                latestArtwork = artwork
                hasArtwork = true
                self.artwork = Self.thumbnail(from: artwork)
                scheduleRender()
                upgradeArtworkIfNeeded(snapshot, token: artworkToken)
            }
        } else if trackChanged {
            let identity = snapshot.artworkIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.trackID
            if identity != currentArtworkIdentity {
                upgradeArtworkIfNeeded(snapshot, token: artworkToken)
            }
        } else if !snapshot.inTransition && !hadTrack {
            hasArtwork = false
        }

        syncIdleWallpaper()
        statusMessage = nil
        emptyReads = 0
        generation += 1
        onPlaybackChange?()
        if isOverlayPresented {
            onSearchChange?()
        }
    }

    private var sourcePlayerQuit: Bool {
        switch playbackSource {
        case PlayerKind.music.sourceID:
            !PlayerScript.isRunning(.music)
        case PlayerKind.spotify.sourceID:
            !PlayerScript.isRunning(.spotify)
        default:
            false
        }
    }

    /// Music and Spotify drop the playing session when they quit. The local clock must stop with them.
    private func stoppedIfPlayerQuit(_ snapshot: NowPlayingSnapshot) -> NowPlayingSnapshot {
        guard sourcePlayerQuit else { return snapshot }
        var snapshot = snapshot
        snapshot.rate = 0
        snapshot.infoRate = 0
        return snapshot
    }

    private func notePlaybackStopped() {
        guard clock.isPlaying else { return }
        clock.anchorElapsed = clock.elapsed(at: .now)
        clock.anchorDate = .now
        clock.rate = 0
        syncIdleWallpaper()
        generation += 1
        onPlaybackChange?()
    }

    private func adoptClock(_ proposed: PlaybackClock) {
        let drift = abs(clock.elapsed(at: .now) - proposed.anchorElapsed)
        let rateChanged = abs(clock.rate - proposed.rate) > 0.01
        let durationChanged = abs(clock.duration - proposed.duration) > 0.5
        let maxDrift: TimeInterval = proposed.isPlaying ? 0.32 : 0.12
        if !hasClock || rateChanged || durationChanged || drift > maxDrift {
            clock = proposed
            hasClock = true
        }
    }

    private func syncIdleWallpaper() {
        idleTask?.cancel()
        guard hasArtwork, !preferences.keepArtworkWhenIdle, !clock.isPlaying, !isPreparingPlayback else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            guard !self.clock.isPlaying, !self.isPreparingPlayback, !self.preferences.keepArtworkWhenIdle else { return }
            self.wallpaper.restoreOriginals()
        }
    }

    private func debouncedRender() {
        appearanceTask?.cancel()
        appearanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self?.scheduleRender()
        }
    }

    private func scheduleRender() {
        guard hasArtwork, !latestArtwork.isEmpty else { return }
        if !preferences.keepArtworkWhenIdle, !clock.isPlaying, !isPreparingPlayback { return }
        let artwork = latestArtwork
        let token = artworkToken
        let style = preferences.style
        let dim = preferences.dim
        let specs = targetSpecs()
        guard !specs.isEmpty else { return }
        let screenKey = specs.map { "\($0.displayID):\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: ",")
        let key = "\(token)|\(style.rawValue)|\(String(format: "%.2f", dim))|\(screenKey)"
        let directory = wallpaper.directory

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let files = await Self.renderFiles(
                artwork: artwork,
                specs: specs,
                style: style,
                dim: dim,
                directory: directory
            )
            guard !Task.isCancelled, let self else { return }
            if let message = files.error {
                self.statusMessage = message
                return
            }
            self.renderedScreenKey = screenKey
            self.commit(files.files, key: key)
        }
    }

    private nonisolated static func renderFiles(
        artwork: Data,
        specs: [ScreenRenderSpec],
        style: WallpaperStyle,
        dim: Double,
        directory: URL
    ) async -> (files: [RenderedWallpaper], error: String?) {
        await withCheckedContinuation { continuation in
            ArtworkRenderer.renderQueue.async {
                guard let image = ImageDecoding.cgImage(from: artwork) else {
                    continuation.resume(returning: ([], "Albüm kapağı okunamadı."))
                    return
                }
                var files: [RenderedWallpaper] = []
                for spec in specs {
                    guard let jpeg = ArtworkRenderer.jpeg(
                        artwork: image,
                        spec: spec,
                        style: style,
                        dim: CGFloat(dim)
                    ) else { continue }
                    let url = directory.appendingPathComponent("wallpaper-\(spec.displayID)-\(UUID().uuidString).jpg")
                    do {
                        try jpeg.write(to: url, options: .atomic)
                        files.append(RenderedWallpaper(displayID: spec.displayID, filePath: url.path))
                    } catch {
                        continuation.resume(returning: ([], error.localizedDescription))
                        return
                    }
                }
                continuation.resume(returning: (files, nil))
            }
        }
    }

    private func commit(_ files: [RenderedWallpaper], key: String) {
        guard !files.isEmpty else { return }
        let update = wallpaper.setWallpapers(files, key: key)
        if let error = update.error {
            statusMessage = error
        }
        guard update.didChange else {
            for file in files {
                try? FileManager.default.removeItem(atPath: file.filePath)
            }
            return
        }
        onWallpaperReady?(files)
    }

    private func loadLyricsIfNeeded() {
        guard !title.isEmpty, trackID != loadedLyricsTrack else { return }
        loadedLyricsTrack = trackID
        lyrics = .empty
        lyricsResolved = false
        lyricsTask?.cancel()
        let artist = artist
        let title = title
        let album = album
        let duration = clock.duration
        let requestedTrack = trackID
        lyricsTask = Task { [weak self] in
            let document = await LyricsClient.fetch(
                artist: artist,
                title: title,
                album: album,
                duration: duration
            )
            guard !Task.isCancelled, let self, self.trackID == requestedTrack else { return }
            self.lyrics = document
            self.lyricsResolved = true
            self.generation += 1
            self.onPlaybackChange?()
        }
    }

    private func report(_ message: String) {
        statusMessage = message
    }

    private func upgradeArtworkIfNeeded(_ snapshot: NowPlayingSnapshot, token: String) {
        upgradeTask?.cancel()
        let expectedTrackID = snapshot.trackID
        upgradeTask = Task { [weak self] in
            var data = await ArtworkURL.sharperData(
                artist: snapshot.artist,
                album: snapshot.album,
                title: snapshot.title,
                identifier: snapshot.artworkIdentifier
            )
            if data == nil, snapshot.isMusicApp || snapshot.source == PlayerKind.music.sourceID {
                if let self, let local = await self.libraryIndex.track(
                    storeID: snapshot.storeID,
                    title: snapshot.title,
                    artist: snapshot.artist,
                    album: snapshot.album
                ) {
                    data = await LibraryCatalog.artworkData(id: local.id)
                }
                if data == nil {
                    data = await PlayerScript.currentMusicArtwork()
                }
            }
            guard !Task.isCancelled, let data else { return }
            self?.installUpgradedArtwork(
                data,
                previousToken: token,
                expectedTrackID: expectedTrackID,
                identifier: snapshot.artworkIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.trackID
            )
        }
    }

    private func installUpgradedArtwork(
        _ data: Data,
        previousToken: String,
        expectedTrackID: String,
        identifier: String
    ) {
        guard trackID == expectedTrackID, artworkToken == previousToken else { return }
        let upgradedToken = "\(identifier)#\(data.count)"
        guard upgradedToken != artworkToken else { return }
        currentArtworkIdentity = identifier
        latestArtwork = data
        hasArtwork = true
        artworkToken = upgradedToken
        artwork = Self.thumbnail(from: data)
        scheduleRender()
        publishPlayback()
    }

    private func targetSpecs() -> [ScreenRenderSpec] {
        let screens = preferences.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        return screens.map(\.renderSpec)
    }

    private static func subtitle(for snapshot: NowPlayingSnapshot) -> String {
        let parts = [snapshot.artist, snapshot.album].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let source = snapshot.sourceName, !source.isEmpty { return source }
        return "Çalan bir parça bekleniyor"
    }

    private static func thumbnail(from data: Data) -> NSImage? {
        guard let image = ImageDecoding.cgImage(from: data, maxPixelSize: 180) else { return nil }
        let size = NSSize(width: image.width, height: image.height)
        return NSImage(cgImage: image, size: size)
    }
}

private struct SearchArtJob: Sendable {
    var key: String
    var url: URL?
    var artist: String
    var album: String
    var title: String
    var libraryID: String?
    var playlistID: String?
    var artistID: Int?
}

private enum SearchArtLoader {
    static func data(for job: SearchArtJob) async -> Data? {
        let file = LibraryDiskCache.cachedArtwork(forKey: job.key)
        if let cached = read(file) { return cached }
        if let playlistID = job.playlistID, let custom = LibraryCatalog.playlistArtworkData(id: playlistID) {
            write(custom, to: file)
            return custom
        }
        if let libraryID = job.libraryID, let cached = read(LibraryDiskCache.legacyArtwork(id: libraryID)) {
            write(cached, to: file)
            return cached
        }
        var remote = job.url
        if remote == nil, let artistID = job.artistID {
            remote = await CatalogSearch.artistArtwork(artistID: artistID)
        }
        if remote == nil, job.playlistID == nil {
            remote = await CatalogSearch.remoteArtwork(artist: job.artist, album: job.album, title: job.title)
        }
        if let remote, let downloaded = await CatalogSearch.artworkData(from: remote) {
            write(downloaded, to: file)
            return downloaded
        }
        if let libraryID = job.libraryID, let local = await LibraryCatalog.artworkData(id: libraryID) {
            write(local, to: file)
            return local
        }
        return nil
    }

    private static func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count > 32 else { return nil }
        return data
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
