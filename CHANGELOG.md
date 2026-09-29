# Changelog

What changed in Hark, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Each release is also on the [Releases](https://github.com/isitanth/hark/releases) page, with its disk image.

## [Unreleased]

### Added

- A polite ending may follow the app in a voice command: "ouvre Safari, s'il te plaît", "open Safari please". The
  phrases are listed under `endings:` in commands.yaml; without that key they are "please", "s'il te plaît" and
  "s'il vous plaît", and `endings: {}` turns them off. Settings › Commands shows them.
- "Arke" counts as the name at the start of a request, like "Hark", "Arc" and "Ark".

### Changed

- "application", "appli" and "app" are skipped words in voice commands, so "Hark, ouvre-moi l'application Messages"
  opens Messages.

### Fixed

- A commands.yaml that was never edited, from 0.0.3 or 0.0.4, now takes the current default at launch. Before, it
  kept the verbs of the version that installed it. An edited file is never replaced.

## [0.0.4] - 2026-09-29

### Added

- The Ask key (⌃⌥A by default): hold it while you speak, or tap it to start and again to stop. With text selected,
  it is Ask Hark on that text, with Replace. With nothing selected, it is the assistant: ask a question or for a piece
  of writing, and the answer streams into the panel, with Insert at the cursor when a text field has focus, else Copy.
- "Hark, …" on the talk key does the same, with "Hey", "Hello" or "Salut" allowed before the name. Whisper writes a
  French "Hark" as "Arc", so "Arc" and "Ark" count too. "Hark, open Safari" still opens Safari.
- The Ask key and "Hark, …" read the selection through Accessibility, and with ⌘C only in apps where Accessibility
  returns nothing (web pages, Mail, Chromium and Electron apps), with the clipboard put back. Never in editors where
  ⌘C copies the whole line, never in a password field.
- Voice commands know the tu, vous and nous forms of the French verbs ("ouvre", "ouvrez", "ouvrons"), and skip small
  words inside an app name.

### Changed

- Before Replace or Insert, Hark checks the selection in those apps too, and compares words rather than white space.
- The panel's recent list marks asks and shows the model's time. When the model server has a problem, the panel says
  which one and which Settings tab fixes it.

### Fixed

- Dictation types into a Mail draft. It used to go to the clipboard.

## [0.0.3] - 2026-09-28

### Added

- Ask Hark: select text in any app, choose Services › Ask Hark, and say what to do with it ("summarize this", "make
  it a bulleted list", "translate into English", or a question). The answer streams into a panel at the top right of
  the screen, where you can edit it, then Replace the selection (⌘↩), Copy it, or Cancel (Esc).
- Settings › Ask: the address of an OpenAI-compatible model server (one on your Mac by default) and its API key, kept
  in the Keychain. Dictation and commands never depend on it.
- The log records each ask as one line, with the model and its time. The selected text and the answer are never
  written to disk.

### Changed

- commands.yaml is version 3, with an optional `llm:` block. Version 2 files still read.
- Replace checks first that the same app is in front and its selection has not changed; otherwise the answer goes to
  the clipboard. The panel can be dragged and remembers where you leave it.

## [0.0.2] - 2026-09-28

The first public release.

### Added

- Dictation into the focused field: press ⌃⌥V to start and again to stop, or hold it and let go. ⌃⌥Esc cancels.
- Voice commands: an opening verb and an app, "open Safari", "ouvre le Finder". Everything else is dictated as text.
- Local transcription with whisper.cpp, on the GPU with the Neural Engine for the encoder. Three models: Small, Medium
  and Large v3, downloaded in Settings › Model.
- English and French: the language is detected on each utterance, or fixed in Settings. The app comes in both.
- The clipboard when no text field has focus, with a notification. Text for a password field is copied concealed and
  kept out of the log.
- A recording panel with the voice's spectrum, the elapsed time and an optional live transcript. Other audio is
  lowered while you speak.
- The log: one JSON line per utterance, in `~/Library/Application Support/Hark/logs/`.
- Commands in `~/Library/Application Support/Hark/commands.yaml`, edited in Settings › Commands and reloaded when the
  file changes. If an edit breaks it, Hark keeps the last good version and the menu bar icon says so.

[Unreleased]: https://github.com/isitanth/hark/compare/v0.0.4...HEAD
[0.0.4]: https://github.com/isitanth/hark/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/isitanth/hark/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/isitanth/hark/releases/tag/v0.0.2
