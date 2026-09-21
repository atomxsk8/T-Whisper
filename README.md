<p align="center">
  <img src="Resources/TWhisperIcon.svg" alt="T-Whisper logo" width="120" height="120">
</p>

# T-Whisper

A lightweight macOS menu-bar dictation app. Press a hotkey, speak in Thai
or English, and T-Whisper transcribes it with Groq's `whisper-large-v3`,
optionally cleans it up with `gpt-oss-120b`, and inserts the result
directly into whatever text field you were last using.

## Get started in 2 minutes

1. Download `T-Whisper.dmg` and drag it into Applications.
2. Open the app → allow Microphone & Accessibility when prompted.
3. Grab a free API key at [console.groq.com](https://console.groq.com/) and paste it in Settings.
4. Press Fn, speak, then press Fn again to stop. (This is toggle mode, the
   default. Prefer press-and-hold instead? Switch to hold-to-talk mode in
   Settings.)

## Features

- **Global hotkey dictation** — trigger with the Fn key or a custom key
  combo, in either toggle (press to start/stop) or hold-to-talk mode.
- **Fast transcription** — audio is sent to Groq's `whisper-large-v3`
  for Thai/English speech-to-text.
- **Optional transcript clean-up** — normalizes filler words, punctuation,
  and technical/English terminology via Groq's `openai/gpt-oss-120b`.
- **Voice snippets** — define spoken triggers (e.g. "my signature") that
  expand to a fixed block of text instead of being transcribed.
- **Direct insertion** — writes the result into the previously focused
  app via the Accessibility API, falling back to a clipboard paste (or a
  manual-copy prompt) if that isn't possible.
- **Menu-bar only** — no Dock icon; lives entirely in the menu bar.

## Requirements

- macOS 14 or later.
- A [Groq](https://console.groq.com/) API key.
- To build from source instead of using the `.dmg`: a Swift 6 toolchain
  (Xcode 16+ or the standalone Swift toolchain).

## Building from source

Prefer a prebuilt release? Use the `.dmg` from **Get started in 2 minutes**
above — the rest of this section is only for building from a checkout.

```bash
./scripts/build-app.sh
```

This produces `dist/T-Whisper.app`, signed with a stable local
certificate (`T-Whisper Dev`, created automatically on first run) so
Accessibility/Input Monitoring permissions survive rebuilds. Move it to
`/Applications` and launch it, or launch it directly from `dist/`.

To produce the `.dmg` used in the quickstart above instead:

```bash
./scripts/build-dmg.sh
```

This builds the app (via `build-app.sh`) and packages it into
`dist/T-Whisper.dmg`, with an `Applications` symlink alongside it for
drag-to-install.

Alternatively, run it without packaging:

```bash
swift run TWhisper
```

Then follow steps 2-4 under **Get started in 2 minutes** to finish setup.

## Usage

- Press your configured hotkey (or use the menu bar item) to start
  recording; press/release again (depending on mode) to stop.
- T-Whisper transcribes the recording and inserts the text where your
  cursor last was.
- If insertion isn't possible in the target app, the result is copied to
  your clipboard instead — paste manually with ⌘V, or use the app's
  fixed **Paste Last Result** shortcut (⌘⌃V).

## Development

See [AGENTS.md](AGENTS.md) for architecture, code conventions, and test
details. Quick reference:

```bash
swift build            # debug build
swift test             # run the test suite
swift build -c release # release build
```

## License

No license file is currently included in this repository.
