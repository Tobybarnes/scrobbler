# Scrobbler

A macOS menubar app that scrobbles your currently playing music to Last.fm.

## Requirements

- macOS 13+
- Xcode 15+
- A Last.fm account with an API application

## Building

1. Clone the repo
2. Open `Scrobbler.xcodeproj` in Xcode
3. Build and run (⌘R)

## Setup

On first launch, the app will prompt you for your Last.fm API credentials.

To get them:
1. Go to [last.fm/api/account/create](https://www.last.fm/api/account/create)
2. Create a new application (name it anything)
3. Copy the **API key** and **Shared secret** — the secret is only shown once, so save it somewhere safe (e.g. your password manager)
4. Paste both into the app's setup dialog

Credentials are stored in your Mac's Keychain and never leave your machine.

## How it works

- Polls the currently playing track every 10 seconds via AppleScript
- Scrobbles a track after it has played for 50% of its duration (or 4 minutes, whichever is less), per Last.fm's scrobbling rules
- Runs as a menubar app with no Dock icon
