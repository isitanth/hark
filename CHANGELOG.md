# Changelog

What changed in Hark, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Each release is also on the [Releases](https://github.com/isitanth/hark/releases) page, with its disk image.

## [Unreleased]

## [0.0.8] - 2026-10-23

Settings redrawn: a resizable window with its panes in a sidebar, in macOS 26's Liquid Glass design, and Hark can
show in the Dock.

### Added

- Settings › General › Show Hark in the Dock: Hark gets a Dock icon, a place in ⌘Tab and its own menus, and a
  click on the icon with no window open opens Settings. Off by default; Hark stays in the menu bar either way.

### Changed

- Settings is a normal window with the panes in a sidebar. It can be resized, remembers its size and place, and
  every pane fills it: the commands table and the log list take the extra height. ⌘, opens it.
- On macOS 26 and later, Settings, the menu bar panel and onboarding take the Liquid Glass design; they were drawn in
  the macOS 15 look.
- Scroll bars in Hark's windows hide when you are not scrolling, also with a mouse connected, as they do with a
  trackpad alone. "Show scroll bars: Always" in System Settings keeps them on show; Hark reads that setting when it
  starts, so a change to it takes effect the next time Hark opens.

### Fixed

- Settings › Commands is no longer cut off above and below its table.
- The Settings panes line up: in Commands, the opening verbs, skipped words and polite endings start at the same
  column and the table names its Test column; in Model, the note and Delete all models… sit in line with the
  models; Log keeps the same side margins as the other panes.
- Delete all models… and each model's Delete… are readable in dark mode: plain buttons, with the red kept for
  their confirmation, which deleting one model now asks for as well.

## [0.0.7] - 2026-10-23

### Changed

- The Settings tabs all have the same width and are evenly spaced, so the selection is the same size on every tab;
  the window is a little wider so all seven fit.

## [0.0.6] - 2026-10-23

Ask Hark keeps the conversation: follow an answer up with the Ask key, in words or with another part of the
screen, until you close the panel.

### Added

- Ask Hark keeps the conversation: while an answer shows, press the Ask key again and keep talking about the same
  selection or frame, and hold ⌃⌥ to show it another part of the screen as you go; closing the panel ends the
  conversation, and the frames go with it.

### Changed

- Settings › About ends with "Engineered with ❤️" in every language.
- While the Ask panel is open, the talk key says how to close it before dictating, instead of doing nothing.

### Fixed

- The Ask panel, on macOS 26 and later, and the recording panel no longer show a thin dark rectangle around their
  rounded corners: their shadows follow the rounded edge.
- Hark relaunched right after quitting could start without its speech model, and every dictation and ask then failed
  until the next restart. It now loads the selected model at every launch.

## [0.0.5] - 2026-10-22

A better Liquid Glass design for the Ask panel, in line with macOS 27's Human Interface Guidelines. Screen context:
show Hark part of the screen while you ask, for richer requests, with a gesture that stays out of the way.

### Added

- A polite ending may follow the app in a voice command: "ouvre Safari, s'il te plaît", "open Safari please". The
  phrases are listed under `endings:` in commands.yaml; without that key they are "please", "s'il te plaît" and
  "s'il vous plaît", and `endings: {}` turns them off. Settings › Commands shows them.
- "Arke" counts as the name at the start of a request, like "Hark", "Arc" and "Ark".
- Ask Hark can use Claude: pick Claude (Anthropic) under Settings › Ask › Provider, paste a key from the Claude
  Console and test it. Hark speaks Anthropic's Messages API (`api: anthropic` in a profile of commands.yaml), with
  `claude-opus-5-5` at low effort by default. Each provider keeps its own key in the Keychain, so switching back to
  the local server keeps its key.
- Ask Hark can see part of your screen: during an ask, hold ⌃⌥ and drag a frame around what you mean, and keep
  talking. The frame goes to the model with your words, and the model first says in one line what it understood you
  want, then answers. The frame stays in memory and is never written to disk or to the log; when the model is not on
  this Mac, the panel names where it goes. macOS asks for Screen & System Audio Recording the first time you frame
  something, and again after about a month without a capture. With the disk image's ad hoc signature, it asks again
  after each update.
- Hark says when a model cannot read images, and why: the model named, MTPLX running in AR mode, or the permission
  missing, each with what to do. Settings › Ask shows whether the model reads images and whether Hark may capture the
  screen.

### Changed

- The menu bar icon is a drill, like the app icon, and its shape says what Hark is doing: an outline at rest, filled
  while it records, with a dot when the recording is hands-free, the battery alone while it transcribes, a sparkle
  while the model answers, "!" for a problem to look at, and a cross for a second when what you said came to nothing.
  Three short animations go with it: the trigger when a recording starts, the bit turning while Hark works, and a
  shake when something failed. None play when Reduce Motion is on.
- "application", "appli" and "app" are skipped words in voice commands, so "Hark, ouvre-moi l'application Messages"
  opens Messages.
- The Ask panel is redrawn in Liquid Glass, following macOS 27's Human Interface Guidelines, on macOS 26 and later;
  it keeps its look on earlier versions.

### Fixed

- A commands.yaml that was never edited, from 0.0.3 or 0.0.4, now takes the current default at launch. Before, it
  kept the verbs of the version that installed it. An edited file is never replaced.
- The last words of an answer no longer go missing from the Ask panel when they arrive just as the answer ends.

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

[Unreleased]: https://github.com/isitanth/hark/compare/v0.0.8...HEAD
[0.0.8]: https://github.com/isitanth/hark/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/isitanth/hark/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/isitanth/hark/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/isitanth/hark/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/isitanth/hark/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/isitanth/hark/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/isitanth/hark/releases/tag/v0.0.2
