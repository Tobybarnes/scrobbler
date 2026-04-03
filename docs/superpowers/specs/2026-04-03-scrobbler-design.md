# Scrobbler — Design Spec
_2026-04-03_

## Overview

A lightweight macOS menu bar app written in Swift that watches Apple Music and scrobbles listening history to Last.fm. Personal use only — no multi-account support, no subscription requirements, no unnecessary complexity.

---

## Architecture

Five components, each with a single responsibility. Data flows one way: `MusicPoller` → `ScrobbleEngine` → `LastFMClient`. The menu bar observes state passively and never drives logic.

`MusicPoller` publishes `TrackState?` via a Combine `PassthroughSubject`. `ScrobbleEngine` subscribes on the main queue. `AppDelegate` also subscribes to observe state for UI updates.

| Component | Responsibility |
|---|---|
| `AppDelegate` | Owns `NSStatusItem`, wires all components together, handles app lifecycle |
| `MusicPoller` | Timer-based AppleScript poller (every 5s). Queries `Music.app` for current track, artist, album, duration, player position, and playback state. Publishes a `TrackState` value. |
| `ScrobbleEngine` | Consumes `TrackState` updates. Tracks accumulated playback time. Fires `updateNowPlaying` on track change, fires `scrobble` when threshold is met. |
| `LastFMClient` | All Last.fm HTTP calls: `auth.getToken`, `auth.getSession`, `track.updateNowPlaying`, `track.scrobble`, `track.love` |
| `SessionStore` | Reads and writes the Last.fm session key to macOS Keychain. Single source of truth for auth state. |

---

## Apple Music Detection

**Method:** AppleScript polling via `NSAppleScript` or `Process` running `osascript`.

**Interval:** Every 5 seconds.

**Data extracted per poll:**
- Track name
- Artist name
- Album name
- Track duration (seconds)
- Current player position (seconds)
- Player state (playing / paused / stopped)

**Why AppleScript over MusicKit or MediaRemote:** Reliable, well-documented, no private APIs, trivially debuggable. The 5-second polling lag is imperceptible for scrobbling purposes.

---

## Scrobbling Logic

### `track.updateNowPlaying`
Called immediately when a new track is detected. No playback threshold required.

### `track.scrobble`
Called once when both conditions are satisfied:
- Played for at least **30 seconds**
- Played for at least **50% of track duration**, or **4 minutes** — whichever comes first

The timestamp sent to Last.fm is the Unix time when the track *started* playing, not when the scrobble fires.

### Edge cases
- **Track skipped before threshold:** no scrobble, engine resets
- **Same track on repeat:** if track identity (track + artist) is unchanged but `position` has decreased by more than 2 seconds relative to the previous poll, treat as a new play — reset the start timestamp and accumulated time, fire `updateNowPlaying` again. Known limitation: manual scrubbing backwards will also trigger this reset, which means accumulated time is lost. Acceptable trade-off for a personal tool.
- **Apple Music quit mid-track:** `MusicPoller` publishes `nil` → engine treats as stopped, suspends accumulation, no scrobble
- **Scrobbling paused by user:** engine stops accumulating time and suppresses both `updateNowPlaying` and `scrobble` calls. Accumulated time for the current track is discarded — if the user resumes scrobbling, the next track starts fresh. This avoids complex partial-play accounting.

### Pause scrobbling
User toggles "Pause scrobbling" / "Resume scrobbling" from the dropdown. The engine holds a `isScrobblingEnabled: Bool` flag. When false: no API calls are made and the status dot turns grey. The menu item label toggles between "Pause scrobbling" and "Resume scrobbling" accordingly.

---

## Authentication

One-time desktop auth flow (Last.fm Desktop How-To):

1. App launches → `SessionStore` checks Keychain → no session key found
2. Menu bar shows: `♫ Not connected · ● (amber)`
3. User clicks "Connect to Last.fm" in dropdown
4. App calls `auth.getToken` → opens `https://www.last.fm/api/auth/?api_key=<key>&token=<token>` in default browser. The dropdown now shows two items: "Waiting for approval…" (disabled) and "I've approved it" (enabled).
5. User approves on Last.fm → returns to app → clicks "I've approved it" in the dropdown
6. App calls `auth.getSession` with token → stores returned session key in Keychain → dropdown returns to normal
7. Authenticated state persists indefinitely

**Error paths during auth:**
- `auth.getSession` returns error 14 (token not authorised): user hasn't approved yet. Show an alert: "It looks like you haven't approved access yet. Try again after approving on Last.fm." Token is retained in memory so the user can try again without restarting the flow.
- `auth.getSession` returns error 15 (token expired): token window has passed. Show alert: "The authorisation expired. Please try connecting again." Clear the in-memory token and restart from step 3.
- Any other error: show alert with the error message, restart from step 3.

The in-memory token (from step 4) is never written to disk or Keychain — it only lives long enough to complete the auth exchange.

To reset: user clicks "Disconnect from Last.fm" → session key deleted from Keychain → back to step 1.

**Credentials:**
- API key and shared secret are compiled into the app (personal use, no distribution)
- Session key stored in Keychain only — never on disk in plaintext

---

## Menu Bar UI

### Status item (always visible)

```
♫  Track Name — Artist Name  ●
```

| State | Text | Dot colour |
|---|---|---|
| State | Text | Dot colour |
|---|---|---|
| Playing + scrobbling active | Track — Artist | Red |
| Playing + scrobbling paused | Track — Artist | Grey |
| Nothing playing | Not playing | — |
| Not authenticated | Not connected | Amber |
| API / network error | Track — Artist (or Not playing) | Amber |

Amber dot covers two distinct states — not authenticated, and runtime error. The dropdown clarifies which: in the not-authenticated state the only menu item is "Connect to Last.fm"; in the error state the normal menu is shown plus an error message at the top (e.g. "Last.fm unreachable"). The dot clears back to red/grey once the next successful API call completes.

Track name truncated at 30 characters with a trailing ellipsis (hard truncation, no word boundary).

### Dropdown menu

```
NOW PLAYING
● Track Name
  Artist · Album

RECENT SCROBBLES
Artist A          × 4
Artist B          × 2
Artist C          × 1

♡ Love this track
⏸ Pause scrobbling   (or Resume scrobbling)
─────────────────
Disconnect from Last.fm
Quit
```

Recent scrobbles shows artists grouped with a count for the current session (in-memory only, resets on quit). Top 5 artists shown, ordered by count descending. If no scrobbles have fired yet this session, the "RECENT SCROBBLES" section is hidden entirely.

The status item truncates the track name at 30 characters with a trailing ellipsis. The artist name is not truncated — if both are long, the combined string may be wide, which is acceptable for a personal tool.

### Love this track
"Love this track" calls `track.love` for the currently playing track (track + artist). It is only enabled when a track is actively playing. It is not a toggle — there is no unlove in the UI. Failure is silent (console log only, no amber dot) — this is a deliberate decision because `track.love` is a nice-to-have action, not core scrobbling, and showing an error state for it would be disproportionate.

---

## Data Model

```swift
enum PlayerState {
    case playing
    case paused
    case stopped
}

struct TrackState {
    let track: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let playerState: PlayerState
}
```

`MusicPoller` publishes `TrackState?` — nil when Music.app is not running or AppleScript returns an error. `ScrobbleEngine` treats nil as stopped: no scrobble, accumulation suspended. The `unavailable` concept is represented solely by nil; there is no `.unavailable` case in `PlayerState`.

No persistent storage beyond the Keychain session key. Scrobble history shown in the menu is in-memory only.

---

## Error Handling

- **Last.fm API errors (non-auth):** Log to console, show amber dot on status item. Dot clears on next successful API call.
- **No internet / network failure:** Scrobble and `updateNowPlaying` calls fail silently — no amber dot, no retry queue. Personal tool, silent failure is acceptable.
- **AppleScript failure (Music.app not running):** Publish nil from `MusicPoller`, treat as stopped state in UI — show "Not playing". No amber dot.
- **Auth expired/revoked:** API returns error code 9 → clear session key from Keychain → show amber dot → prompt re-auth via dropdown.

---

## Out of Scope

- Offline scrobble queue / retry
- Album art display
- Multiple Last.fm accounts
- Preferences window
- Launch-at-login toggle (can be set manually in System Settings → General → Login Items)
- Spotify or other music sources
