import SwiftUI

struct ControlBarView: View {
    var model: AppModel
    var generation: Int
    var mover: WindowMover
    var onSearchHeight: (CGFloat) -> Void
    @State private var isScrubbing = false
    @State private var scrubFraction = 0.0
    @Namespace private var searchSelectionSpace
    @Namespace private var scopeSpace

    var body: some View {
        let playback = model.clock
        let trackTitle = model.title
        let _ = generation
        GeometryReader { geo in
            let scale = max(0.75, geo.size.width / ControlChrome.baseWidth)
            let layout = searchLayout(scale: scale)
            VStack(spacing: 0) {
                if layout.cardHeight > 0 {
                    searchCard(layout)
                        .padding(.bottom, layout.gap)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                }
                VStack(spacing: 4 * scale) {
                    header(scale: scale, title: trackTitle)
                    transport(scale: scale)
                    if model.clock.duration > 1 {
                        TimelineView(.animation(minimumInterval: 0.1, paused: !playback.isPlaying || isScrubbing)) { timeline in
                            let elapsed = isScrubbing
                                ? playback.duration * scrubFraction
                                : playback.elapsed(at: timeline.date)
                            progress(elapsed: elapsed, scale: scale)
                        }
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 8 * scale, y: scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: model.overlayMode)
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: layout.cardHeight)
            .animation(.snappy(duration: 0.28), value: model.trackID)
            .onChange(of: layout.extraHeight) { _, height in
                onSearchHeight(height)
            }
            .onAppear {
                onSearchHeight(layout.extraHeight)
            }
        }
    }

    private func header(scale: CGFloat, title: String) -> some View {
        ZStack {
            titleBlock(scale: scale, title: title)
                .opacity(model.isSearchPresented ? 0 : 1)
                .allowsHitTesting(!model.isSearchPresented)
                .accessibilityHidden(model.isSearchPresented)
            if model.isSearchPresented {
                searchField(scale: scale)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.isSearchPresented)
    }

    private func titleBlock(scale: CGFloat, title: String) -> some View {
        let subText: String = if model.isPreparingPlayback, !title.isEmpty {
            model.subtitle.isEmpty ? "Parça hazırlanıyor…" : "Hazırlanıyor · \(model.subtitle)"
        } else {
            model.subtitle
        }
        return HStack(spacing: 8 * scale) {
            VStack(spacing: 1 * scale) {
                Text(title.isEmpty ? "Çalan bir şey yok" : title)
                    .font(.system(size: 13 * scale, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subText)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
            .gesture(dragGesture)
            .help("Sürükleyerek taşı. Ortaya ve diğer pencereye yapışır.")
        }
    }

    private func searchField(scale: CGFloat) -> some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 16 * scale, height: 16 * scale)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }
                .gesture(dragGesture)
                .help("Sürükleyerek taşı")
            LibrarySearchField(
                text: model.searchQuery,
                placeholder: searchPlaceholder,
                fontSize: 13 * scale,
                wantsFocus: model.isSearchPresented,
                focusToken: model.searchFocusToken,
                onText: { model.setSearchQuery($0) },
                onMove: { model.moveSearchSelection(by: $0) },
                onSubmit: { direct in
                    if direct {
                        model.playSelectedSearchResultDirectly()
                    } else {
                        model.playSelectedSearchResult()
                    }
                },
                onToggleScope: {
                    if model.searchStack.isEmpty {
                        model.toggleSearchScope()
                    }
                },
                onCancel: { model.popSearchPage() }
            )
            .frame(height: 18 * scale)
            .id("library-search-field")
            fieldAccessory(scale: scale)
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 5 * scale)
        .background {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(.white.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
                }
        }
        .help(model.searchScope == .appleMusic
            ? "Yazdıkça Apple Music eşleşmeleri listelenir"
            : "Yazdıkça kitaplıktaki eşleşmeler listelenir")
    }

    @ViewBuilder
    private func fieldAccessory(scale: CGFloat) -> some View {
        if model.searchScope == .library, model.libraryStatus == .loading, model.libraryCount == 0 {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(width: 16 * scale, height: 16 * scale)
        } else {
            Button {
                if model.searchQuery.isEmpty {
                    model.collapseOverlay()
                } else {
                    model.clearSearchQuery()
                }
            } label: {
                Image(systemName: model.searchQuery.isEmpty ? "xmark" : "xmark.circle.fill")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16 * scale, height: 16 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.searchQuery.isEmpty ? "Aramayı kapat" : "Temizle")
        }
    }

    private var searchPlaceholder: String {
        if model.searchScope == .appleMusic {
            return "Şarkı, sanatçı veya albüm"
        }
        switch model.libraryStatus {
        case .loading where model.libraryCount == 0:
            return "Kitaplık hazırlanıyor…"
        case .unavailable:
            return "Müzik kitaplığı gerekli"
        case .ready where model.libraryCount == 0:
            return "Kitaplıkta şarkı yok"
        default:
            return "Şarkı, sanatçı veya albüm"
        }
    }

    private func transport(scale: CGFloat) -> some View {
        let buttonWidth: CGFloat = 50
        return HStack(spacing: 5 * scale) {
            MarkButton(
                systemName: "backward.fill",
                label: "Önceki parça",
                size: 11 * scale,
                scale: scale,
                widthFactor: buttonWidth
            ) {
                model.previous()
            }
            MarkButton(
                systemName: model.clock.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPreparingPlayback ? "Hazırlanıyor…" : (model.clock.isPlaying ? "Duraklat" : "Oynat"),
                size: 15 * scale,
                scale: scale,
                widthFactor: buttonWidth,
                isBusy: model.isPreparingPlayback
            ) {
                model.playPause()
            }
            MarkButton(
                systemName: "forward.fill",
                label: "Sonraki parça",
                size: 11 * scale,
                scale: scale,
                widthFactor: buttonWidth
            ) {
                model.next()
            }
            MarkButton(
                systemName: model.preferences.lyricsVisible ? "quote.bubble.fill" : "quote.bubble",
                label: model.preferences.lyricsVisible ? "Sözleri gizle" : "Sözleri göster",
                size: 12 * scale,
                scale: scale,
                widthFactor: buttonWidth,
                isActive: model.preferences.lyricsVisible
            ) {
                model.preferences.lyricsVisible.toggle()
            }
            MarkButton(
                systemName: "music.note.list",
                label: model.isPlaylistsPresented ? "Listeleri kapat" : "Çalma listeleri (⌘L)",
                size: 12.5 * scale,
                scale: scale,
                widthFactor: buttonWidth,
                isActive: model.isPlaylistsPresented
            ) {
                model.togglePlaylists()
            }
            .onHover { inside in
                if inside { model.prepareLibrarySearch() }
            }
            MarkButton(
                systemName: "magnifyingglass",
                label: model.isSearchPresented ? "Aramayı kapat" : "Şarkı ara (⌘F)",
                size: 13 * scale,
                scale: scale,
                widthFactor: buttonWidth,
                isActive: model.isSearchPresented
            ) {
                model.toggleSearch()
            }
            .onHover { inside in
                if inside { model.prepareLibrarySearch() }
            }
        }
        .padding(.top, 2 * scale)
    }

    private func searchCard(_ layout: SearchLayout) -> some View {
        let radius = 14 * layout.scale
        return VStack(spacing: 0) {
            searchHeader(layout)
                .frame(height: layout.headerHeight)
            if layout.contentHeight > 0 {
                searchBody(layout)
                    .frame(height: layout.contentHeight)
            }
        }
        .padding(.bottom, layout.bottomInset)
        .frame(height: layout.cardHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.black.opacity(0.7))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.7)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 18 * layout.scale, y: 8 * layout.scale)
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private func searchHeader(_ layout: SearchLayout) -> some View {
        if model.isPlaylistsPresented {
            playlistsHeader(layout)
        } else {
            HStack(spacing: 8 * layout.scale) {
                if let page = model.searchStack.last {
                    Button {
                        model.popSearchPage()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12 * layout.scale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 22 * layout.scale, height: 22 * layout.scale)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Geri")
                    Text(page.title)
                        .font(.system(size: 13 * layout.scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.collapseOverlay()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5 * layout.scale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 22 * layout.scale, height: 22 * layout.scale)
                            .background(Circle().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Kapat")
                } else {
                    HStack(spacing: 3 * layout.scale) {
                        scopeChoice(.library, layout)
                        scopeChoice(.appleMusic, layout)
                    }
                    .padding(3 * layout.scale)
                    .background {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                    }
                }
                if showsSearchSpinner {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
            }
            .padding(.horizontal, 10 * layout.scale)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.searchScope)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.searchStack.count)
        }
    }

    private func playlistsHeader(_ layout: SearchLayout) -> some View {
        HStack(spacing: 8 * layout.scale) {
            if let page = model.activePlaylistPage {
                Button {
                    model.popPlaylistPage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12 * layout.scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 22 * layout.scale, height: 22 * layout.scale)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Tüm listeler")
                Text(page.title)
                    .font(.system(size: 13 * layout.scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 12 * layout.scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Text("Çalma Listeleri")
                    .font(.system(size: 13 * layout.scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !model.savedPlaylists.isEmpty {
                    Text("\(model.savedPlaylists.count)")
                        .font(.system(size: 10.5 * layout.scale, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 6 * layout.scale)
                        .padding(.vertical, 2 * layout.scale)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            Spacer(minLength: 0)
            if model.libraryStatus == .loading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else if model.activePlaylistPage == nil {
                Button {
                    model.refreshPlaylists()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5 * layout.scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 22 * layout.scale, height: 22 * layout.scale)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Listeleri yenile")
            }
            Button {
                model.collapseOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5 * layout.scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 22 * layout.scale, height: 22 * layout.scale)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Kapat")
        }
        .padding(.horizontal, 10 * layout.scale)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.activePlaylistPage?.id)
    }

    private func scopeChoice(_ scope: SearchScope, _ layout: SearchLayout) -> some View {
        let selected = model.searchScope == scope
        return Button {
            model.setSearchScope(scope)
        } label: {
            Text(scope.title)
                .font(.system(size: 11 * layout.scale, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.58))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5 * layout.scale)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.2))
                            .matchedGeometryEffect(id: "search-scope", in: scopeSpace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var showsSearchSpinner: Bool {
        if !model.searchStack.isEmpty, model.detailState == .loading { return true }
        switch model.searchScope {
        case .library:
            return model.libraryStatus == .loading && model.libraryCount > 0
        case .appleMusic:
            return model.catalogState == .loading
        }
    }

    @ViewBuilder
    private func searchBody(_ layout: SearchLayout) -> some View {
        switch layout.mode {
        case .hidden:
            EmptyView()
        case .shimmer:
            SearchShimmer(scale: layout.scale, rowHeight: layout.rowHeight)
        case .message:
            searchMessage(layout)
        case .history:
            searchHistoryList(layout)
        case .playlists:
            playlistsBrowser(layout)
        case .results:
            searchBrowser(layout)
        }
    }

    private func playlistsBrowser(_ layout: SearchLayout) -> some View {
        VStack(spacing: 0) {
            if let page = model.activePlaylistPage {
                playlistHero(page, layout: layout)
                if model.activePlaylistSongs.isEmpty {
                    if model.libraryStatus == .loading {
                        SearchShimmer(scale: layout.scale, rowHeight: layout.rowHeight)
                    } else {
                        Text("Listede şarkı bulunamadı")
                            .font(.system(size: 12 * layout.scale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    playlistTrackList(model.activePlaylistSongs, layout: layout)
                }
            } else if model.savedPlaylists.isEmpty {
                playlistsEmptyMessage(layout)
            } else {
                playlistDirectoryList(model.savedPlaylists, layout: layout)
            }
        }
    }

    private func playlistHero(_ page: SearchItem, layout: SearchLayout) -> some View {
        HStack(spacing: 12 * layout.scale) {
            SearchArtwork(
                image: model.searchArtwork[page.artworkKey],
                title: page.title,
                kind: .playlist,
                scale: layout.scale,
                side: 52 * layout.scale
            )
            .onAppear { model.ensureArtwork(for: page) }
            VStack(alignment: .leading, spacing: 2 * layout.scale) {
                Text(page.title)
                    .font(.system(size: 15 * layout.scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(page.subtitle)
                    .font(.system(size: 11 * layout.scale))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                model.playPlaylist(page, shuffled: true)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 11.5 * layout.scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 30 * layout.scale, height: 30 * layout.scale)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(PressScaleStyle())
            .help("Karışık çal")

            Button {
                model.playPlaylist(page, shuffled: false)
            } label: {
                ZStack {
                    Circle().fill(.white)
                    if model.isPreparingPlayback && model.currentPlayingPlaylistID == page.resolvedPlaylistID {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12 * layout.scale, weight: .bold))
                            .foregroundStyle(.black.opacity(0.86))
                    }
                }
                .frame(width: 32 * layout.scale, height: 32 * layout.scale)
            }
            .buttonStyle(PressScaleStyle())
            .help("Listeyi baştan çal")
        }
        .padding(.horizontal, 12 * layout.scale)
        .padding(.bottom, 6 * layout.scale)
        .frame(height: layout.heroHeight)
    }

    private func playlistDirectoryList(_ items: [SearchItem], layout: SearchLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SearchResultRow(
                            model: model,
                            item: item,
                            tokens: [],
                            scale: layout.scale,
                            rowHeight: layout.rowHeight,
                            isSelected: index == model.playlistSelection,
                            index: index,
                            selectionSpace: searchSelectionSpace,
                            play: { model.openPlaylist(item) },
                            quickPlay: { model.playPlaylist(item, shuffled: false) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 4 * layout.scale)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.playlistSelection) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
            }
        }
    }

    private func playlistTrackList(_ items: [SearchItem], layout: SearchLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SearchResultRow(
                            model: model,
                            item: item,
                            tokens: [],
                            scale: layout.scale,
                            rowHeight: layout.rowHeight,
                            isSelected: index == model.playlistSelection,
                            index: min(index, 6),
                            selectionSpace: searchSelectionSpace,
                            trackIndexBadge: index + 1,
                            play: { model.playPlaylistSong(item) },
                            quickPlay: { model.playPlaylistSong(item) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 4 * layout.scale)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.playlistSelection) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
            }
        }
    }

    private func playlistsEmptyMessage(_ layout: SearchLayout) -> some View {
        VStack(spacing: 8 * layout.scale) {
            Text(model.libraryStatus == .loading ? "Çalma listeleri yükleniyor…" : "Kayıtlı çalma listesi bulunamadı.")
                .font(.system(size: 12 * layout.scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .multilineTextAlignment(.center)
            if model.libraryStatus != .loading {
                Button {
                    model.refreshPlaylists()
                } label: {
                    Text("Yeniden Dene")
                        .font(.system(size: 11 * layout.scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10 * layout.scale)
                        .padding(.vertical, 5 * layout.scale)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14 * layout.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchHistoryList(_ layout: SearchLayout) -> some View {
        let entries = model.searchHistory
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8 * layout.scale) {
                        Text("Son Aramalar")
                            .font(.system(size: 11 * layout.scale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        Rectangle()
                            .fill(.white.opacity(0.18))
                            .frame(height: 1)
                            .frame(maxWidth: .infinity)
                        Button {
                            model.clearSearchHistory()
                        } label: {
                            Text("Temizle")
                                .font(.system(size: 10.5 * layout.scale, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12 * layout.scale)
                    .padding(.top, 8 * layout.scale)
                    .padding(.bottom, 5 * layout.scale)

                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        SearchHistoryRow(
                            model: model,
                            entry: entry,
                            scale: layout.scale,
                            rowHeight: layout.rowHeight,
                            isSelected: index == model.searchSelection,
                            selectionSpace: searchSelectionSpace,
                            select: { model.selectHistoryEntry(entry) },
                            quickPlay: { model.playHistoryEntryDirectly(entry) },
                            remove: { model.removeSearchHistory(entry.id) }
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 4 * layout.scale)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.searchSelection) { _, index in
                guard entries.indices.contains(index) else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    proxy.scrollTo(entries[index].id, anchor: .center)
                }
            }
        }
    }

    private func searchBrowser(_ layout: SearchLayout) -> some View {
        VStack(spacing: 0) {
            if let page = model.searchStack.last {
                searchHero(page, layout: layout)
            }
            if model.searchStack.isEmpty {
                if !model.searchResults.isEmpty {
                    searchHitList(model.searchResults, layout: layout)
                }
            } else if model.detailState == .loading, model.searchFocusItems.isEmpty {
                SearchShimmer(scale: layout.scale, rowHeight: layout.rowHeight)
            } else if model.searchFocusItems.isEmpty {
                Text(model.detailState == .failed ? "Ayrıntılar yüklenemedi." : "İçerik bulunamadı")
                    .font(.system(size: 12 * layout.scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchHitList(model.searchFocusItems, layout: layout)
            }
        }
    }

    private func searchHero(_ page: SearchItem, layout: SearchLayout) -> some View {
        let heroHelp: String = switch page.kind {
        case .artist: "Sanatçıyı çal"
        case .album: "Albümü çal"
        case .playlist: "Listeyi çal"
        case .song: "Parçayı çal"
        }
        return HStack(spacing: 12 * layout.scale) {
            SearchArtwork(
                image: model.searchArtwork[page.artworkKey],
                title: page.title,
                kind: page.kind,
                scale: layout.scale,
                side: 52 * layout.scale
            )
            VStack(alignment: .leading, spacing: 2 * layout.scale) {
                Text(page.title)
                    .font(.system(size: 15 * layout.scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(page.kind == .artist ? (page.songCount > 0 ? "Sanatçı · \(page.songCount) şarkı" : "Sanatçı") : page.subtitle)
                    .font(.system(size: 11 * layout.scale))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                model.playSearchItem(page, dismissAfter: false)
            } label: {
                ZStack {
                    Circle().fill(.white)
                    if model.isPreparingPlayback {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12 * layout.scale, weight: .bold))
                            .foregroundStyle(.black.opacity(0.86))
                    }
                }
                .frame(width: 32 * layout.scale, height: 32 * layout.scale)
            }
            .buttonStyle(PressScaleStyle())
            .help(heroHelp)
        }
        .padding(.horizontal, 12 * layout.scale)
        .padding(.bottom, 6 * layout.scale)
        .frame(height: layout.heroHeight)
    }

    private func searchSectionHeader(_ title: String, scale: CGFloat, isFirst: Bool) -> some View {
        HStack(spacing: 8 * scale) {
            Text(title)
                .font(.system(size: 11 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.top, (isFirst ? 8 : 14) * scale)
        .padding(.bottom, 5 * scale)
    }

    private func searchHitList(_ items: [SearchItem], layout: SearchLayout) -> some View {
        let tokens = LibraryMatch.tokens(in: model.searchQuery)
        let showsSections = Set(items.map(\.kind)).count > 1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if showsSections, index == 0 || items[index - 1].kind != item.kind {
                            searchSectionHeader(item.kind.sectionTitle, scale: layout.scale, isFirst: index == 0)
                        }
                        SearchResultRow(
                            model: model,
                            item: item,
                            tokens: tokens,
                            scale: layout.scale,
                            rowHeight: layout.rowHeight,
                            isSelected: index == model.searchSelection,
                            index: index,
                            selectionSpace: searchSelectionSpace,
                            play: { model.selectSearchItem(item) },
                            quickPlay: { model.playSearchItem(item, dismissAfter: model.searchStack.isEmpty) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 4 * layout.scale)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.searchSelection) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
            }
            .onChange(of: items.map(\.id)) { _, ids in
                guard let id = ids.first else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func searchMessage(_ layout: SearchLayout) -> some View {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8 * layout.scale) {
            Text(searchMessageText)
                .font(.system(size: 12 * layout.scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.searchScope == .library, case .unavailable(.notRunning) = model.libraryStatus {
                Button {
                    model.openMusicForSearch()
                } label: {
                    Text("Kitaplığı Yükle")
                        .font(.system(size: 11 * layout.scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10 * layout.scale)
                        .padding(.vertical, 5 * layout.scale)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            } else if model.searchScope == .library, !query.isEmpty {
                Button {
                    model.setSearchScope(.appleMusic)
                } label: {
                    HStack(spacing: 4 * layout.scale) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 10 * layout.scale, weight: .semibold))
                        Text("Apple Music’te Ara")
                            .font(.system(size: 11 * layout.scale, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11 * layout.scale)
                    .padding(.vertical, 5 * layout.scale)
                    .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(.horizontal, 14 * layout.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(searchMessageHelp)
    }

    private var searchMessageText: String {
        if model.searchScope == .appleMusic {
            return model.catalogState == .failed ? "Apple Music araması yapılamadı." : "Eşleşen bir şey yok"
        }
        switch model.libraryStatus {
        case .unavailable(.notRunning):
            return "Müzik kitaplığı hazır değil."
        case .unavailable(.automation):
            return "Müzik’i denetleme izni gerekli."
        case .unavailable(.failed):
            return "Kitaplık okunamadı."
        case .ready where model.libraryCount == 0:
            return "Kitaplıkta şarkı yok."
        default:
            return "Kitaplıkta eşleşen bir şey yok"
        }
    }

    private var searchMessageHelp: String {
        if model.searchScope == .library, case .unavailable(.automation) = model.libraryStatus {
            return "Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon bölümünden Coverdesk’in Müzik’i denetlemesine izin ver."
        }
        return searchMessageText
    }

    private func searchLayout(scale: CGFloat) -> SearchLayout {
        let rowHeight = 46 * scale
        let headerHeight = 40 * scale
        let bottomInset = 8 * scale
        let gap = 8 * scale
        let heroHeight = 72 * scale
        func make(_ mode: SearchCardMode, content: CGFloat) -> SearchLayout {
            SearchLayout(
                scale: scale,
                rowHeight: rowHeight,
                headerHeight: headerHeight,
                heroHeight: heroHeight,
                contentHeight: content,
                bottomInset: bottomInset,
                gap: gap,
                mode: mode
            )
        }
        switch model.overlayMode {
        case .none:
            return make(.hidden, content: 0)
        case .playlists:
            if model.activePlaylistPage != nil {
                let songs = model.activePlaylistSongs
                let listHeight: CGFloat = if songs.isEmpty {
                    model.libraryStatus == .loading ? rowHeight * 3 : 56 * scale
                } else {
                    CGFloat(min(songs.count, 6)) * rowHeight
                }
                return make(.playlists, content: heroHeight + listHeight)
            }
            if model.savedPlaylists.isEmpty {
                let emptyHeight = model.libraryStatus == .loading ? rowHeight * 3 : 74 * scale
                return make(.playlists, content: emptyHeight)
            }
            let listHeight = CGFloat(min(model.savedPlaylists.count, 7)) * rowHeight
            return make(.playlists, content: listHeight)
        case .search:
            break
        }

        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.searchStack.isEmpty {
            let items = model.searchFocusItems
            let list = items.isEmpty
                ? (model.detailState == .loading ? rowHeight * 3 : 46 * scale)
                : hitListHeight(items, scale: scale, rowHeight: rowHeight, cap: 6)
            return make(.results, content: heroHeight + list)
        }
        if !model.searchResults.isEmpty {
            return make(.results, content: hitListHeight(model.searchResults, scale: scale, rowHeight: rowHeight, cap: 7))
        }
        if query.isEmpty, !model.searchHistory.isEmpty {
            let rows = CGFloat(min(model.searchHistory.count, 6)) * rowHeight
            return make(.history, content: 28 * scale + rows)
        }
        if model.searchScope == .appleMusic {
            guard !query.isEmpty else { return make(.message, content: 0) }
            if model.catalogState == .loading || query != model.settledSearchQuery {
                return make(.shimmer, content: rowHeight * 3)
            }
            return make(.message, content: 46 * scale)
        }
        if case .unavailable = model.libraryStatus {
            let content = model.libraryStatus == .unavailable(.notRunning) ? 78 * scale : 54 * scale
            return make(.message, content: content)
        }
        if model.libraryStatus == .ready, model.libraryCount == 0 {
            return make(.message, content: (query.isEmpty ? 46 : 78) * scale)
        }
        guard !query.isEmpty else { return make(.message, content: 0) }
        if model.libraryStatus == .loading || model.libraryStatus == .idle {
            return make(.shimmer, content: rowHeight * 3)
        }
        if query != model.settledSearchQuery {
            return make(.message, content: 0)
        }
        return make(.message, content: 78 * scale)
    }

    private func hitListHeight(_ items: [SearchItem], scale: CGFloat, rowHeight: CGFloat, cap: Int) -> CGFloat {
        let showsSections = Set(items.map(\.kind)).count > 1
        var height: CGFloat = 0
        var counted = 0
        var last: SearchKind?
        for item in items {
            if showsSections, last != item.kind {
                height += (last == nil ? 28 : 36) * scale
                last = item.kind
            }
            height += rowHeight
            counted += 1
            if counted >= cap { break }
        }
        return height
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { mover.track(translation: $0.translation) }
            .onEnded { _ in mover.finish() }
    }

    private func progress(elapsed: TimeInterval, scale: CGFloat) -> some View {
        let fraction = model.clock.duration > 0 ? min(1, max(0, elapsed / model.clock.duration)) : 0
        return HStack(spacing: 6 * scale) {
            Color.clear
                .frame(width: 14, height: 14)
            Text(formatTime(elapsed))
            GeometryReader { geo in
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: max(2, 2 * scale))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: max(3, geo.size.width * fraction), height: max(2, 2 * scale))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isScrubbing = true
                                scrubFraction = scrubFraction(at: value.location.x, width: geo.size.width)
                            }
                            .onEnded { value in
                                let next = scrubFraction(at: value.location.x, width: geo.size.width)
                                scrubFraction = next
                                model.seek(toFraction: next)
                                isScrubbing = false
                            }
                    )
            }
            .frame(width: 140 * scale, height: 18 * scale)
            Text(formatTime(model.clock.duration))
            ScaleMark()
                .stroke(
                    .white.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.55), radius: 1.2, y: 0.4)
                .background {
                    ScaleAnchor { mover.reportScaleAnchor($0) }
                }
                .allowsHitTesting(false)
        }
        .font(.system(size: 9 * scale, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.72))
    }

    private func scrubFraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width)))
    }
}

private struct SearchLayout {
    var scale: CGFloat
    var rowHeight: CGFloat
    var headerHeight: CGFloat
    var heroHeight: CGFloat
    var contentHeight: CGFloat
    var bottomInset: CGFloat
    var gap: CGFloat
    var mode: SearchCardMode

    var cardHeight: CGFloat {
        guard mode != .hidden else { return 0 }
        return headerHeight + contentHeight + bottomInset
    }

    var extraHeight: CGFloat {
        cardHeight > 0 ? cardHeight + gap : 0
    }
}

private enum SearchCardMode {
    case hidden
    case shimmer
    case message
    case history
    case playlists
    case results
}

private struct SearchArtwork: View {
    var image: NSImage?
    var title: String
    var kind: SearchKind
    var scale: CGFloat
    var side: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: Self.colors(for: title), startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.stroke(.white.opacity(0.14), lineWidth: 0.5) }
    }

    private var symbol: String {
        switch kind {
        case .artist: "person.fill"
        case .album: "square.stack.fill"
        case .playlist: "music.note.list"
        case .song: "music.note"
        }
    }

    private var shape: AnyShape {
        if kind == .artist {
            AnyShape(Circle())
        } else {
            AnyShape(RoundedRectangle(cornerRadius: max(4, side * 0.18), style: .continuous))
        }
    }

    private static func colors(for title: String) -> [Color] {
        var hash = 0
        for byte in title.utf8 {
            hash = (hash &* 31 &+ Int(byte)) & 0x7fff_ffff
        }
        let hue = Double(hash % 360) / 360
        return [
            Color(hue: hue, saturation: 0.42, brightness: 0.62),
            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.34),
        ]
    }
}

private struct SearchHistoryRow: View {
    var model: AppModel
    var entry: SearchHistoryEntry
    var scale: CGFloat
    var rowHeight: CGFloat
    var isSelected: Bool
    var selectionSpace: Namespace.ID
    var select: () -> Void
    var quickPlay: () -> Void
    var remove: () -> Void
    @State private var isHovering = false
    @State private var isHoveringPlay = false
    @State private var isHoveringRemove = false

    private var itemKind: SearchKind {
        switch entry.entryKind {
        case .query, .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 10 * scale) {
                    if entry.entryKind == .query {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                                .fill(.white.opacity(0.1))
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 13 * scale, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .frame(width: 34 * scale, height: 34 * scale)
                    } else {
                        ZStack {
                            SearchArtwork(
                                image: model.searchArtwork[entry.artworkKey],
                                title: entry.title,
                                kind: itemKind,
                                scale: scale,
                                side: 34 * scale
                            )
                            if entry.entryKind == .song, isHovering || isSelected {
                                Color.black.opacity(0.28)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11 * scale, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 34 * scale, height: 34 * scale)
                    }

                    VStack(alignment: .leading, spacing: 1 * scale) {
                        Text(entry.title)
                            .font(.system(size: 13 * scale, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .font(.system(size: 11 * scale))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if entry.entryKind == .query, !(isHovering || isSelected) {
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 10 * scale, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
                .padding(.leading, 8 * scale)
                .padding(.trailing, (isHovering || isSelected) ? 4 * scale : 8 * scale)
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())

            if isHovering || isSelected {
                if entry.entryKind != .query && entry.entryKind != .song {
                    Button(action: quickPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9.5 * scale, weight: .bold))
                            .foregroundStyle(isHoveringPlay ? .black.opacity(0.9) : .white.opacity(0.95))
                            .frame(width: 23 * scale, height: 23 * scale)
                            .background {
                                Circle().fill(isHoveringPlay ? .white : .white.opacity(0.2))
                            }
                    }
                    .buttonStyle(PressScaleStyle())
                    .onHover { isHoveringPlay = $0 }
                    .help("Hemen çal")
                    .padding(.trailing, 4 * scale)
                }

                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(isHoveringRemove ? 0.95 : 0.5))
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background {
                            if isHoveringRemove {
                                Circle().fill(.white.opacity(0.16))
                            }
                        }
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRemove = $0 }
                .help("Geçmişten kaldır")
                .padding(.trailing, 6 * scale)
            }
        }
        .frame(height: rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .matchedGeometryEffect(id: "search-selection", in: selectionSpace)
                    .padding(.horizontal, 2 * scale)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .padding(.horizontal, 2 * scale)
            }
        }
        .onHover { inside in
            isHovering = inside
            if !inside {
                isHoveringPlay = false
                isHoveringRemove = false
            }
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onAppear {
            if let item = entry.asSearchItem {
                model.ensureArtwork(for: item)
            }
        }
    }
}

private struct SearchResultRow: View {
    var model: AppModel
    var item: SearchItem
    var tokens: [String]
    var scale: CGFloat
    var rowHeight: CGFloat
    var isSelected: Bool
    var index: Int
    var selectionSpace: Namespace.ID
    var trackIndexBadge: Int? = nil
    var play: () -> Void
    var quickPlay: () -> Void
    @State private var isHovering = false
    @State private var isHoveringQuickPlay = false
    @State private var isShown = false

    private var displayedTrackNumber: Int? {
        if let trackIndexBadge, trackIndexBadge > 0 { return trackIndexBadge }
        if item.kind == .song, item.trackNumber > 0, model.searchStack.last?.kind == .album {
            return item.trackNumber
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: play) {
                HStack(spacing: 10 * scale) {
                    ZStack {
                        SearchArtwork(
                            image: model.searchArtwork[item.artworkKey],
                            title: item.title,
                            kind: item.kind,
                            scale: scale,
                            side: 34 * scale
                        )
                        if item.kind == .song, isCurrent, !isHovering {
                            Color.black.opacity(0.32)
                            Image(systemName: model.clock.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.system(size: 10.5 * scale, weight: .bold))
                                .foregroundStyle(.white)
                        } else if item.kind == .song, isHovering || isSelected {
                            Color.black.opacity(0.28)
                            Image(systemName: "play.fill")
                                .font(.system(size: 11 * scale, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 34 * scale, height: 34 * scale)
                    .clipShape(artworkShape)
                    .animation(.easeOut(duration: 0.22), value: model.searchArtwork[item.artworkKey] != nil)
                    if let number = displayedTrackNumber {
                        Text("\(number)")
                            .font(.system(size: 11 * scale, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.46))
                            .frame(width: 20 * scale, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 1 * scale) {
                        highlighted(
                            item.title,
                            size: 13 * scale,
                            matched: .semibold,
                            plain: .regular,
                            matchedOpacity: 1,
                            plainOpacity: 0.5,
                            fallback: .medium,
                            fallbackOpacity: 1
                        )
                        .lineLimit(1)
                        if !item.subtitle.isEmpty {
                            highlighted(
                                item.subtitle,
                                size: 11 * scale,
                                matched: .semibold,
                                plain: .regular,
                                matchedOpacity: 0.95,
                                plainOpacity: 0.48,
                                fallback: .regular,
                                fallbackOpacity: 0.62
                            )
                            .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        if model.isPreparingPlayback {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        } else {
                            Image(systemName: model.clock.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 10 * scale, weight: .semibold))
                                .foregroundStyle(.white.opacity(model.clock.isPlaying ? 0.9 : 0.6))
                        }
                    }
                    if item.kind == .song, item.duration > 1 {
                        Text(formatTime(item.duration))
                            .font(.system(size: 10 * scale, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.48))
                    } else if item.kind != .song, !(isHovering || isSelected) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10 * scale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
                .padding(.leading, 8 * scale)
                .padding(.trailing, item.kind != .song && (isHovering || isSelected) ? 4 * scale : 8 * scale)
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())

            if item.kind != .song, isHovering || isSelected {
                Button(action: quickPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9.5 * scale, weight: .bold))
                        .foregroundStyle(isHoveringQuickPlay ? .black.opacity(0.9) : .white.opacity(0.95))
                        .frame(width: 24 * scale, height: 24 * scale)
                        .background {
                            Circle()
                                .fill(isHoveringQuickPlay ? .white : .white.opacity(0.2))
                        }
                }
                .buttonStyle(PressScaleStyle())
                .onHover { isHoveringQuickPlay = $0 }
                .help(quickPlayLabel)
                .padding(.trailing, 4 * scale)

                Button(action: play) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 14 * scale, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6 * scale)
            }
        }
        .frame(height: rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .matchedGeometryEffect(id: "search-selection", in: selectionSpace)
                    .padding(.horizontal, 2 * scale)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .padding(.horizontal, 2 * scale)
            }
        }
        .onHover { inside in
            isHovering = inside
            if !inside { isHoveringQuickPlay = false }
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .accessibilityLabel("\(item.title), \(item.subtitle)")
        .opacity(isShown ? 1 : 0)
        .scaleEffect(isShown ? 1 : 0.985, anchor: .leading)
        .onAppear {
            isShown = true
            model.ensureArtwork(for: item)
        }
        .animation(
            .spring(response: 0.38, dampingFraction: 0.82).delay(min(0.12, Double(index) * 0.03)),
            value: isShown
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
    }

    private var quickPlayLabel: String {
        switch item.kind {
        case .artist: "Sanatçıyı hemen çal"
        case .album: "Albümü hemen çal"
        case .playlist: "Listeyi hemen çal"
        case .song: "Çal"
        }
    }

    private var isCurrent: Bool {
        model.isCurrentItem(item)
    }

    private var artworkShape: AnyShape {
        if item.kind == .artist {
            AnyShape(Circle())
        } else {
            AnyShape(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
        }
    }

    private func highlighted(
        _ text: String,
        size: CGFloat,
        matched: Font.Weight,
        plain: Font.Weight,
        matchedOpacity: Double,
        plainOpacity: Double,
        fallback: Font.Weight,
        fallbackOpacity: Double
    ) -> Text {
        let ranges = LibraryMatch.ranges(in: text, tokens: tokens)
        guard !ranges.isEmpty else {
            return Text(text)
                .font(.system(size: size, weight: fallback))
                .foregroundStyle(.white.opacity(fallbackOpacity))
        }
        var cursor = text.startIndex
        var pieces: [Text] = []
        for range in ranges where range.lowerBound >= cursor && range.upperBound <= text.endIndex {
            if cursor < range.lowerBound {
                pieces.append(styled(text[cursor..<range.lowerBound], size: size, weight: plain, opacity: plainOpacity))
            }
            pieces.append(styled(text[range], size: size, weight: matched, opacity: matchedOpacity))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            pieces.append(styled(text[cursor..<text.endIndex], size: size, weight: plain, opacity: plainOpacity))
        }
        return pieces.reduce(Text(""), +)
    }

    private func styled(_ text: Substring, size: CGFloat, weight: Font.Weight, opacity: Double) -> Text {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(opacity))
    }
}

private struct SearchShimmer: View {
    var scale: CGFloat
    var rowHeight: CGFloat
    @State private var phase = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 10 * scale) {
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(.white.opacity(0.1))
                        .frame(width: 32 * scale, height: 32 * scale)
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(width: (120 + CGFloat(index * 18)) * scale, height: 8 * scale)
                        Capsule()
                            .fill(.white.opacity(0.08))
                            .frame(width: 78 * scale, height: 6 * scale)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12 * scale)
                .frame(height: rowHeight)
                .opacity(phase ? 0.45 : 0.95)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(index) * 0.12),
                    value: phase
                )
            }
        }
        .onAppear { phase = true }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    var text: String
    var placeholder: String
    var fontSize: CGFloat
    var wantsFocus: Bool
    var focusToken: Int
    var onText: (String) -> Void
    var onMove: (Int) -> Void
    var onSubmit: (Bool) -> Void
    var onToggleScope: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onText: onText,
            onMove: onMove,
            onSubmit: onSubmit,
            onToggleScope: onToggleScope,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.cell?.sendsActionOnEndEditing = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        field.stringValue = text
        field.delegate = context.coordinator
        applyPlaceholder(field)
        context.coordinator.wantsFocus = wantsFocus
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.focus(field)
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.onText = onText
        context.coordinator.onMove = onMove
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onToggleScope = onToggleScope
        context.coordinator.onCancel = onCancel
        context.coordinator.wantsFocus = wantsFocus
        if field.stringValue != text {
            field.stringValue = text
        }
        if abs((field.font?.pointSize ?? 0) - fontSize) > 0.4 {
            field.font = .systemFont(ofSize: fontSize, weight: .medium)
        }
        if context.coordinator.placeholder != placeholder {
            context.coordinator.placeholder = placeholder
            applyPlaceholder(field)
        }
        guard wantsFocus, context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        guard field.window?.firstResponder !== field.currentEditor() else { return }
        context.coordinator.focus(field)
    }

    private func applyPlaceholder(_ field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.42),
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            ]
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var wantsFocus = false
        var lastFocusToken = -1
        var placeholder = ""
        var onText: (String) -> Void
        var onMove: (Int) -> Void
        var onSubmit: (Bool) -> Void
        var onToggleScope: () -> Void
        var onCancel: () -> Void

        init(
            onText: @escaping (String) -> Void,
            onMove: @escaping (Int) -> Void,
            onSubmit: @escaping (Bool) -> Void,
            onToggleScope: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onText = onText
            self.onMove = onMove
            self.onSubmit = onSubmit
            self.onToggleScope = onToggleScope
            self.onCancel = onCancel
        }

        func focus(_ field: NSTextField, attempt: Int = 0) {
            guard wantsFocus else { return }
            guard let window = field.window else {
                guard attempt < 6 else { return }
                DispatchQueue.main.async { [weak self, weak field] in
                    guard let self, let field else { return }
                    self.focus(field, attempt: attempt + 1)
                }
                return
            }
            window.makeFirstResponder(field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onText(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let cmdDown = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                onSubmit(cmdDown)
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                onToggleScope()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class SearchTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .white
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor.white.withAlphaComponent(0.28),
                .foregroundColor: NSColor.white,
            ]
        }
        return accepted
    }
}

private struct MarkButton: View {
    var systemName: String
    var label: String
    var size: CGFloat
    var scale: CGFloat
    var widthFactor: CGFloat = 56
    var isBusy = false
    var isActive = false
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.2 : (isActive ? 0.14 : 0.02)))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                                .strokeBorder(.white.opacity(0.24), lineWidth: 0.6)
                        }
                    }
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovering || isActive ? 1 : 0.88))
                }
            }
            .frame(width: widthFactor * scale, height: 46 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

struct CornerHandles: View {
    var body: some View {
        ScaleMark()
            .stroke(
                .white.opacity(0.9),
                style: StrokeStyle(lineWidth: 1.35, lineCap: .round)
            )
            .frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.55), radius: 1.2, y: 0.4)
            .padding(.trailing, 18)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
    }
}

private struct ScaleAnchor: NSViewRepresentable {
    var onChange: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard view.window != nil, view.bounds.width > 1 else { return }
        onChange(view.convert(view.bounds, to: nil).insetBy(dx: -6, dy: -6))
    }
}

private struct ScaleMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = min(rect.width, rect.height) * 0.12
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
            control: CGPoint(x: rect.maxX - inset * 2.2, y: rect.maxY - inset * 2.2)
        )
        return path
    }
}

private func formatTime(_ time: TimeInterval) -> String {
    guard time.isFinite, time > 0 else { return "0:00" }
    let total = Int(time.rounded(.down))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}
