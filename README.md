# Coverdesk

Coverdesk is a macOS menu bar app that turns the album art of whatever you're listening to into your desktop wallpaper.

It reads from the system Now Playing session, so it works with Apple Music, Spotify, browsers, and anything else that reports media playback to macOS. When a track changes, Coverdesk fetches high-resolution artwork if available, renders it to match your display resolution, and crossfades the desktop background. When you pause or quit, it can put your original wallpaper back.

## What's included

- Two wallpaper layouts (full cover and centered poster) with adjustable dimming so desktop icons stay readable, across single or multiple displays.
- A compact control bar and optional synced lyrics view that live on the desktop layer behind your open windows instead of getting in the way. Both can be dragged, resized, or set to float above windows from settings.
- Built-in search (`Cmd + F`) for your local Music library and the Apple Music catalog, plus a saved playlists view (`Cmd + L`). Selecting a song, album, or playlist queues and starts playback in the background without bringing the Music window to the front.

## Download

Grab the latest `.dmg` or `.zip` from [Releases](https://github.com/ArdaKestane/Coverdesk/releases) and move `Coverdesk.app` to `/Applications`. Requires macOS 14 Sonoma or newer.

Because the app is ad-hoc signed rather than notarized with an Apple Developer ID, macOS will block it on the first launch. Right-click `Coverdesk.app` and choose **Open** (or allow it under **System Settings > Privacy & Security**). On first use with Apple Music, macOS will also ask for Automation permission so Coverdesk can control playback.

## Building from source

Requires Xcode or the Command Line Tools (Swift 6, macOS 14 SDK).

Build `build/Coverdesk.app` for your current architecture:

```sh
./scripts/package-app.sh
```

Build a universal binary and package both the installer `.dmg` and `.zip` into `build/`:

```sh
./scripts/make-dmg.sh
```
