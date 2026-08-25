# GSD — Get Sh*t Done

<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="GSD icon" />
</p>

A minimal menu bar todo app for macOS. Plain markdown files, zero cloud, keyboard-first.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6.2-orange)

<p align="center">
  <img src="Resources/demo.png" alt="GSD in action" />
  <br />
  <em>Your daily tasks, one hotkey away.</em>
</p>

## Install

**Homebrew (recommended):**

```bash
brew install --cask encore-ai-labs/gsd/gsd
```

Upgrades: `brew upgrade --cask gsd`.

**Direct download:** grab the latest `GSD-<version>.dmg` from [Releases](https://github.com/encore-ai-labs/gsd/releases), drag GSD to Applications, launch. The app is signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper warnings.

**Build from source:**

```bash
git clone https://github.com/encore-ai-labs/gsd.git
cd gsd
swift build -c release --arch arm64 --arch x86_64
# Binary at .build/apple/Products/Release/GSD
```

## Usage

**Cmd+0** toggles the popover from anywhere.

- Type tasks with markdown checkboxes: `- [ ] task`
- Click the checkbox prefix to toggle done/undone
- Press Enter on a checkbox line to add another
- **Cmd+B** / **Cmd+I** for bold/italic
- Unchecked tasks sort to the top, checked sink to the bottom
- Incomplete tasks automatically carry forward to the next day

### Pointer-safe screenshots

Press **Cmd+Shift+2** while the pointer is over a hover state, tooltip, menu, or other
UI you want to preserve. GSD opens a non-activating selection overlay, so the pointer
does not move and the app underneath keeps focus.

- **Arrow keys** move the capture area; **Option+Arrow** moves it one point
- **Shift+Arrow** resizes the area; **Space** cycles common sizes
- **Return** captures; **Escape** cancels
- In the preview, **Return** or **Cmd+C** copies the image; **Escape** discards it
- Uncopied captures auto-discard after 20 seconds

Screenshots are ephemeral: GSD keeps the pending image in memory and never writes a
screenshot file to disk. Copying places TIFF image data on the macOS clipboard.

## Features

- **Menu bar app** — lives in your status bar, one hotkey away
- **Plain markdown** — files stored at `~/.gsd/` as standard `.md`, open them in any editor
- **Live formatting** — headers, bold, italic, strikethrough rendered inline as you type
- **Multiple notebooks** — switch between separate note collections
- **Calendar picker** — navigate to any date, dots show which days have notes
- **Search** — full-text search across all your notes
- **Carry-forward** — unchecked tasks from yesterday auto-populate today's note
- **Dark mode** — follows system appearance
- **Pointer-safe screenshots** — capture hover UI by keyboard without moving the pointer
- **No screenshot files** — uncopied captures stay in memory and auto-discard

## Data

Notes are plain markdown files stored in `~/.gsd/<notebook>/YYYY-MM-DD.md`. No accounts, no sync, no telemetry. Back them up however you like.

## License

MIT
