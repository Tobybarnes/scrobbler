# Scrobbler

A small macOS menu bar app that watches Apple Music and scrobbles what you're
listening to back to Last.fm. It's a personal tool, written for myself, no
multi-account support, no settings screen, no telemetry.

## What it does

Sits in the menu bar, polls Apple Music every five seconds, and sends
`updateNowPlaying` and `scrobble` calls to Last.fm using the standard rules:
a track scrobbles once it has played for at least 30 seconds and either past
the halfway mark or four minutes, whichever lands first. You can pause
scrobbling, love the current track, and disconnect from the dropdown.

The menu bar title shows the current track and a coloured dot for status.
Green when scrobbling is live, grey when paused, amber when something is
wrong with auth or the API.

## Requirements

* macOS 13 or later
* Apple Music (the desktop app, not just the web player)
* A Last.fm account
* A Last.fm API key and shared secret (free, [apply here](https://www.last.fm/api/account/create))
* Xcode 15 with Swift 5.9
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project from `project.yml`

## Build and run

Clone the repo, copy the secrets template into place, fill in your own Last.fm
API credentials, then generate and open the Xcode project:

```bash
cp Secrets.example.swift Scrobbler/Secrets.swift
# edit Scrobbler/Secrets.swift and paste in your apiKey and secret
xcodegen generate
open Scrobbler.xcodeproj
```

`Scrobbler/Secrets.swift` is gitignored, so your keys never end up in version
control. The build will fail until that file exists.

Build the `Scrobbler` scheme. The app launches with no Dock icon, just a
menu bar entry.

## First run

The first time you launch, the menu reads "Not connected". Click "Connect to
Last.fm" and the app opens the Last.fm authorisation page in your browser.
Approve the request there, come back to the menu, and click "I've approved
it". The session key gets stored in your macOS Keychain and the app stays
authenticated until you click "Disconnect from Last.fm".

## Architecture

Five files, one job each.

* `MusicPoller` runs a five-second timer, queries Music.app via AppleScript,
  publishes a `TrackState` through Combine
* `ScrobbleEngine` consumes `TrackState`, accumulates playback time, fires
  the scrobble when the threshold is met
* `LastFMClient` handles the signed HTTP calls (`auth.getToken`,
  `auth.getSession`, `track.updateNowPlaying`, `track.scrobble`, `track.love`)
* `SessionStore` reads and writes the session key to the Keychain
* `AppDelegate` wires everything together and owns the `NSStatusItem`

`MenuController` builds the menu from an `AppState` value. The UI never
drives logic, it only reflects state.

## Tests

The poller and engine are unit tested. Run from Xcode with `Cmd+U` or via
the command line:

```bash
xcodebuild test -scheme Scrobbler -destination "platform=macOS"
```

## Known limitations

Scrubbing backwards on a track resets the accumulated time, so manually
seeking back more than two seconds will look like a replay to the engine.
Acceptable trade off for a personal tool. Pausing scrobbling discards
accumulated time on the current track too, rather than trying to do partial
play accounting.

## Why this exists

Last.fm has a Mac client called Last.app, but it crashes for me regularly
and the project hasn't seen a release in a long time. I wanted something
small and reliable that I could read in an afternoon.

## Licence

MIT. Use it, fork it, swap the API key in, scrobble away.
