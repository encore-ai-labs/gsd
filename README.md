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

1. Download **GSD-1.0.0.dmg** from [Releases](https://github.com/encore-ai-labs/gsd/releases)
2. Drag GSD to Applications
3. Launch — it's signed and notarized, opens without Gatekeeper warnings

Or build from source:

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

## Features

- **Menu bar app** — lives in your status bar, one hotkey away
- **Plain markdown** — files stored at `~/.gsd/` as standard `.md`, open them in any editor
- **Live formatting** — headers, bold, italic, strikethrough rendered inline as you type
- **Multiple notebooks** — switch between separate note collections
- **Calendar picker** — navigate to any date, dots show which days have notes
- **Search** — full-text search across all your notes
- **Carry-forward** — unchecked tasks from yesterday auto-populate today's note
- **Dark mode** — follows system appearance

## Data

Notes are plain markdown files stored in `~/.gsd/<notebook>/YYYY-MM-DD.md`. No accounts, no sync, no telemetry. Back them up however you like.

## License

MIT
