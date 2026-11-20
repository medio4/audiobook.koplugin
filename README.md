<p align="center">
  <img src="new_audio_logo.svg" alt="Audiobook Read-Along logo" width="160">
</p>

<h1 align="center">Audiobook Read-Along for KOReader</h1>

Listen to your books in [KOReader](https://github.com/koreader/koreader) with the text highlighted as it is read. Read-Along plays a book's built-in narration, reads any book aloud with offline text-to-speech, and plays separate audiobook files, over the speaker or Bluetooth headphones.

This is a fork of [stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin), tuned for Kobo. Everything below describes this fork.

## Features

### Listening

- **Built-in audiobooks.** EPUBs with EPUB 3 Media Overlays (Storyteller, BookOrbit) play their own narration, with the publisher's timing driving the highlight and page turns.
- **Read aloud with text-to-speech.** Any EPUB can be read aloud offline. On Kobo the default engine is sanoTTS with the neural "amy" voice; espeak-ng, Piper and others can be picked in **Voice settings**.
- **Separate audiobook files.** Play MP3, M4B/M4A, FLAC, OGG or Opus files with a scrubber, chapter list and speed control, or a music playlist.
- **Audiobookshelf.** Browse, download and sync progress with an [Audiobookshelf](https://www.audiobookshelf.org/) server ([setup](docs/AUDIOBOOKSHELF.md)).
- **Sleep timer**, with an option to put the device to sleep when it ends.
- **Keep playing with the cover closed.**

### Following along

- **Sentence highlight** that follows the audio, with optional **word highlight** (off by default because each word costs an e-ink refresh).
- **Automatic page turns** that keep the spoken sentence on screen. Turn the page yourself and the audio keeps going, with a "Return to read-aloud" cue to jump back.
- **Short-cue grouping** for e-ink, so fast phrases do not flash past.
- **Sync offset** for books whose timing runs ahead of or behind the audio.

### Player

- **Mini player bar** with line back, play/pause and line forward (hold a line button to move by page). Tap it to open the **full-screen player**, which can show the previous, current and next sentence instead of the cover.
- **Large player bar** option with bigger buttons that are easier to hit.
- **Stays on top of in-book menus.** The bar stays visible over menus, lists and dialogs you open from the book. If it is in the way, hold an empty part of it and drag it; it remembers that spot for menus and returns to its place on the page afterwards.
- **Floating player outside the book.** Leave the book (Home or the library) and the narration can keep playing, with a small round player at the bottom of the screen. Tap it for line skip, play/pause, open the book at the narration, stop or hide. Reopening the book picks the narration back up in the page.
- **Gestures.** KOReader gesture actions for *Toggle Read-Along*, *Stop Read-Along* and *Show / hide the floating Read-Along player*.

### Starting from the library

Hold a book's cover (or its row in the library, History, Collections or search results) and its menu can offer:

- **Play audiobook** and **Read aloud (TTS)** for books with built-in narration.
- **Read aloud (TTS)** for books without.

Both are off by default and work in stock KOReader and under ZenOS.

### Bluetooth

- **Connects by itself.** Press play with your saved headphones disconnected and Read-Along turns Bluetooth on and connects them, then starts. A small window with **Cancel** shows while it connects; the usual prompt only appears if it gives up after two minutes.
- **Reconnects when the headphones drop** mid-book: it pauses, reconnects and resumes where you were.
- **Headset buttons** for play/pause and next/previous.
- Works on both Kobo Bluetooth stacks (MediaTek on Clara 2E / Clara BW / Libra Colour and similar, BlueZ on Libra 2 / Sage). On MediaTek models Wi-Fi is switched on briefly to power the Bluetooth chip, then off again.

Some of these were added recently and are still being tried on real devices, so expect rough edges in the floating player, the drag-to-move bar, the library buttons and automatic connecting.

## Install

1. Copy this repository's folder to your device as `audiobook.koplugin` inside KOReader's `plugins` folder (on Kobo: `.adds/koreader/plugins/`).
2. Add the TTS engines. The easiest way is to build a bundle with `bash package-for-kobo.sh` (needs [Nix](https://nixos.org/download); add `--with-piper` for Piper) and copy `kobo-tts-bundle/audiobook.koplugin/` instead. Upstream's release zips contain the same engines.
3. Restart KOReader.

> **Check for updates** in the plugin menu installs upstream's release, which replaces this fork's changes. Update this fork by copying the folder again.

## Use

- **Built-in audiobook:** open the book, then **Tools > Audiobook Read-Along > Play audiobook**, or long-press a word and pick **Play aligned audiobook from here**.
- **Text-to-speech:** long-press a word or select text and pick **Read aloud from here**, or **Tools > Audiobook Read-Along > Read aloud (text-to-speech) from this page**.
- **Audio files:** **Other audio > Play unaligned audiobook** or **Start music playlist** in the same menu.

Settings live in **Tools > Audiobook Read-Along**:

| Where | What |
|-------|------|
| Reading & sync | Follow narration page, page turns move the audiobook, after turning back Play starts from, hold a word to play from there, auto-advance, pause when a menu opens, sync offset |
| Highlighting | Sentences, words, style, group short cues |
| Player bar | Keep the bar, large bar, **Floating player** (Enable, Appear when leaving the book, Appear over in-book menus), hide controls/progress, status bars, page margins, line-by-line view |
| Bluetooth & headset | Pair and connect, headset buttons, auto reconnect, connect as soon as Play is pressed, disconnect alert |
| Voice settings | Engine, voice, speed, pitch, volume, pauses |
| Sleep & lid | Sleep timer, sleep the device when it ends, keep playing with the lid closed |
| When holding a book | The library buttons above (both off by default) |
| Advanced | Audio output options, session recorder, benchmark, bug report, updates, about |

## Troubleshooting

| Problem | Try |
|---------|-----|
| Plugin not in the menu | The folder must be named `audiobook.koplugin`. The menu is under **Tools** with a book open. Restart KOReader. |
| No sound over Bluetooth | Restart KOReader to clear a stuck audio process, and check the headphones are connected in **Bluetooth settings**. |
| Highlight ahead of or behind the voice | **General settings > Overlay sync offset**. |

**Generate bug report** in the plugin menu saves a diagnostic file (device, engines, audio and Bluetooth state; no book content) to the device's storage. KOReader's own `crash.log` is in its folder (`.adds/koreader/` on Kobo).

More detail: [platform audio and Bluetooth](docs/PLATFORM_AUDIO.md), [BookOrbit](docs/BOOKORBIT.md), [Android](docs/ANDROID_TTS.md).

## Credits and license

Read-Along is based on [audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin) by gespitia (stradichenko). Copyright 2025-2026 gespitia. Fork changes are released under the same license.

Licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

| Bundled component | License |
|-------------------|---------|
| [KOReader](https://github.com/koreader/koreader) | AGPL-3.0 |
| [espeak-ng](https://github.com/espeak-ng/espeak-ng) | GPL-3.0+ |
| [Piper](https://github.com/rhasspy/piper) | MIT |
| [Piper voices](https://huggingface.co/rhasspy/piper-voices) | MIT |
| [sanoTTS](https://github.com/ampixa/sanoTTS) (runtime + voice blobs) | MIT |
| [sanoTTS-jp](https://github.com/ayutaz/sanoTTS-jp) (runtime binary, vendored core; weights and dictionary are user downloads) | MIT (core + OpenJTalk subset: modified BSD) |
| glibc (bundled .so) | LGPL-2.1 |
