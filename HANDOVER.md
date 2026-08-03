# Handover: Building Scrobbler on a new Mac

This is a personal macOS menu bar app that scrobbles Apple Music plays to Last.fm. I'm moving it to a new Shopify-managed Mac and I tried copying the built `.app` over but it got blocked by security. Rebuilding from source on the new machine is the way.

This doc is written for a fresh Claude Code session on the new machine. Read it top to bottom before doing anything.

## What this app is

A small menu bar app written in Swift for macOS 13+. It polls the Apple Music desktop app every five seconds and sends `updateNowPlaying` and `scrobble` calls to Last.fm. Standard scrobble rules: a track scrobbles once it has played 30 seconds and either past the halfway mark or four minutes, whichever lands first. The menu bar shows the current track and a coloured status dot.

The repo is at `https://github.com/Tobybarnes/scrobbler`. It's a personal project, not a Shopify one.

## Prerequisites on the new machine

You need all of these before you can build:

1. **Xcode 15 or later.** Install from Self Service or the App Store. This takes a while, run it first.
2. **XcodeGen.** Install with `brew install xcodegen`. The Xcode project file is generated from `project.yml`, not checked in as the source of truth.

Last.fm credentials are entered on first launch and stored in the macOS
Keychain. They are not part of the repository. On a new Mac, choose “Set up
Last.fm credentials…” from the menu and enter the API key and shared secret.

## Build steps

```bash
git clone https://github.com/Tobybarnes/scrobbler.git
cd scrobbler

# Generate the Xcode project
xcodegen generate

# Open and build
open Scrobbler.xcodeproj
```

In Xcode, build the `Scrobbler` scheme. A fresh clone should already contain the app icon, project config, tests, and Last.fm credentials needed to compile.

## First launch

The app uses local/ad-hoc signing (`CODE_SIGN_IDENTITY: "-"` in `project.yml`). Locally-built debug runs from Xcode are normally fine on a Shopify-managed Mac because Xcode handles signing for the launching user. If you hit a Santa block at first launch, request an allowlist exception via Self Service. Mention it's a locally-built personal menu bar tool.

Once the app launches, it appears in the menu bar with no Dock icon. The first time, the menu reads "Not connected". The flow is:

1. Click "Connect to Last.fm" in the menu. The app opens the Last.fm authorisation page in your default browser.
2. Approve the request on the Last.fm page.
3. Come back to the menu and click "I've approved" (or whatever the post-auth menu item is called).
4. The status dot should go green and the menu bar title should start showing whatever Apple Music is playing.

The Last.fm session key is stored in the macOS Keychain under service `com.tobybarnes.scrobbler`, account `lastfm-session`. It does not transfer between machines. The new machine will need its own first-time auth, that's expected.

## What not to do

- Do **not** try to copy the compiled `.app` from the old machine. That's what was blocked. Build locally instead.
- Do **not** check in generated `build/`, `DerivedData/`, `xcuserdata/`, or `.superpowers/`.
- Do **not** flip `ENABLE_HARDENED_RUNTIME` to `YES` or change `CODE_SIGN_IDENTITY` away from `-` unless you actually have a Developer ID set up. The current config is intentionally permissive because this is a personal local build.

## File map

- `project.yml` — XcodeGen spec, the source of truth for build settings
- `Scrobbler/AppDelegate.swift` — wires up the menu bar item, poller, and engine
- `Scrobbler/MenuController.swift` — builds the dropdown menu from app state
- `Scrobbler/ScrobbleEngine.swift` — playback accumulation and scrobble rules
- `Scrobbler/LastFMClient.swift` — Last.fm API calls
- `Scrobbler/CredentialStore.swift` — stores Last.fm credentials in Keychain
- `Scrobbler/SessionStore.swift` — Keychain read/write for the session key
- `Scrobbler/MusicPoller.swift` — polls Apple Music every 5 seconds
- `Secrets.example.swift` — optional template if you ever want to rotate to a different Last.fm API app
- `Scrobbler/Assets.xcassets/` — app icon

## Verification

You'll know everything worked when:

- Xcode builds the `Scrobbler` scheme with zero errors.
- The app appears in the menu bar after running.
- After connecting to Last.fm, the status dot is green and the title shows the current Apple Music track.
- Play a full track in Apple Music and check that it appears in your Last.fm recent scrobbles within a minute of finishing.

If you get stuck, the README has more detail. If something has drifted since this doc was written, trust the code and `project.yml` over this file.
