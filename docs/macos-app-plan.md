# LiteEcho for Mac: design and implementation plan

> **Update (LiteEcho):** the in-app transcript viewer was dropped. Transcripts now open in the default browser, speaker renaming is a sheet from the queue row, and Settings › Appearance offers five themes (Professional default, Cyberpunk, Lite Lime, Echo Mint, Paper Studio).

Status: **draft for approval**. Screen mockups:
<https://claude.ai/artifact/9TRanhqPc4S4Z2RkdgGJSm> (1 Queue, 2 Transcript viewer, 3 First run, 4 Settings).

## Goal

A native macOS app for the LiteEcho engine: drop audio files, get
transcripts with speakers, read them next to the audio. Everything runs on the Mac.
The CLI keeps working, and the app and CLI share one engine and one set of models.

## Architecture

```
LiteEcho.app (SwiftUI, macOS 14+, Apple Silicon)
 ├─ Queue window        ── EngineRunner ──spawns──▶ engine/bin/liteecho <file> --events jsonl
 ├─ Transcript viewer   ── WKWebView (saved HTML) + AVPlayer (the audio)
 ├─ First-run setup     ── bundled `uv` creates the engine; fetch-models downloads the models
 └─ Settings
~/Library/Application Support/LiteEcho/
 ├─ engine/   Python 3.12 venv built from the repo's uv.lock (exact pins → exact reference output)
 ├─ models/   faster-whisper-large-v3-turbo/, speaker-diarization-community-1/ (shared with the CLI)
 └─ queue.json
```

- **UI:** SwiftUI with small AppKit pieces (drop target, Finder reveal, Dock badge).
- **Engine:** the Python package, unchanged in behaviour, run as a child process per job.
  Python is never embedded in the app process. Crashes stay contained and cancelling a job is
  a signal.
- **Engine install:** the app bundles the `uv` binary, `uv.lock`, `pyproject.toml` and the liteecho
  wheel (about 40 MB). On first run, `uv sync --frozen` builds the engine in Application Support. That
  downloads about 1 GB of wheels once, mostly torch. The lock file pins every version the golden test
  depends on.
- **Build without Xcode:** this Mac has only the Command Line Tools (Swift 6.4), so the project is a
  Swift package. `swift build` and Swift Testing both work with the CLT, verified on this machine, and
  `scripts/build-app.sh` assembles `LiteEcho.app` (Info.plist, icon via `iconutil`,
  ad-hoc `codesign`). The package also opens in Xcode if it is installed later.

## Engine protocol (new CLI features)

`liteecho INPUT --events jsonl` turns the progress bars off and prints one JSON object per line
on stdout. Human-readable logs stay on stderr.

| `type` | Fields | When |
|---|---|---|
| `stage` | `stage`: `convert` · `segmentation` · `embeddings` · `transcribe` · `pauses`; `completed`, `total`, `unit` (`s` or `steps`) | progress |
| `language` | `code` | after auto-detection |
| `done` | `output` (HTML path), `sampled` (list of `{start_ms, end_ms}`) | success |
| `error` | `message`, `detail` (traceback) | failure; exit code 1 |

Other new engine commands:

- `liteecho engine-info --json`: engine version, Python and pinned library versions, where each model
  resolves (`cache`, `custom`, `missing`), and whether it verifies.
- `liteecho fetch-models --events jsonl`: download progress as `stage` events (unit `bytes`).
  The token is passed only through the `HF_TOKEN` environment variable, never in argv, because argv
  is visible to other processes.
- `liteecho rename-speakers FILE --map S00=Dana --map S01=Avi`: rewrites speaker labels and
  anchor names in a saved transcript. Names are HTML-escaped
  and sanitised for anchors.
- SIGTERM handling: a cancelled job stops its worker processes and removes temp files.

## Screens (see mockups)

1. **Queue (main window):**
   - The sidebar holds options for new files: language Auto/English/Hebrew, speakers auto or exact,
     and the output location. It also shows model status.
   - A drop zone accepts audio and video, and *Add Files…* opens a file picker.
   - The queue lists each file with its state: per-stage progress (Converting, Finding speakers,
     Transcribing with position and ETA), Cancel, Open transcript and Show in Finder.
   - Files run one at a time, because the models need about 4 GB of memory.
   - The queue survives relaunch.
   - While it runs, the Mac is kept awake, the Dock badge shows the count, and a notification
     appears when a file finishes.
2. **Transcript viewer:**
   - The saved HTML is shown in a WKWebView with readable styling. Hebrew is right-to-left.
   - Clicking a timestamp or line seeks the audio, and the playing line is highlighted.
   - The sidebar renames speakers (through `rename-speakers`) and toggles timestamps, pause marks
     and uncertain passages, which are the randomly sampled spans.
   - The toolbar has search, Export (HTML or plain text) and Open in Browser.
3. **First run:**
   - The engine install happens first, with progress.
   - Then the models: *Import from a folder…* if they are already on this Mac. Otherwise download whisper
     (public), then pyannote, after the user accepts its terms and pastes a Hugging Face token.
   - The token is stored in the Keychain. Every file is checked against the pinned SHA-256.
4. **Settings:**
   - **General:** defaults for language, speakers and output, plus notification, open-when-done and
     keep-awake options.
   - **Models:** location, status, re-verify, re-download.
   - **Advanced:** CPU threads (fixed at 3 in reference-exact mode), keep temp files, show engine log.
   - **Install "liteecho" command:** a symlink in `~/.local/bin`.

## Security

- **Transcript HTML:** the transcript text is escaped by the engine. The viewer still loads it with page
  JavaScript disabled (`allowsContentJavaScript = false`). Click-to-seek runs as a WKUserScript in an
  isolated content world. Links to anything except `#` anchors open in the default browser, never
  inside the web view.
- **Hugging Face token:** kept in the Keychain and passed to the engine only via the environment, only
  for `fetch-models`.
- **Files:** the app reads only files the user dropped or picked and writes only to the chosen output
  folder and its Application Support folder.

## Implementation (after approval)

0. **Me:**
   - Scaffold `app/` (Package.swift, targets `LiteEchoApp` and `LiteEchoCore`, tests).
   - Add shared Swift types for the protocol (`EngineEvent`, `Job`, `JobState`, `ModelStatus`).
   - Add `scripts/build-app.sh` and freeze this protocol.
1. **Engine agent (Python):** `--events jsonl`, `engine-info`, `rename-speakers`, `fetch-models`
   events, SIGTERM cleanup, and tests. Writes only Python files.
2. **Queue agent (Swift):** main window, drop zone, `QueueStore` persistence, `EngineRunner`
   (spawns the process and parses JSONL), notifications, keep-awake, Dock badge, and tests.
3. **Setup and Settings agent (Swift):** first-run flow (engine install with the bundled uv, the
   models step, Keychain token), Settings window, CLI symlink, and tests.
4. **Viewer agent (Swift):** WKWebView viewer, AVPlayer sync, speaker rename, search, export,
   uncertain passages, and tests.
5. **Me:**
   - Integrate, build the .app, and run the 60-second clip end to end.
   - Then run the golden reference file through the app's own engine and check it matches the reference transcript.

Agents 2–4 each own their folder under `app/Sources/LiteEchoApp/` and share only the
types from step 0, so they run in parallel without touching each other's files. They use
Sonnet, and the engine agent can use Haiku.

## Decisions to confirm

- **Distribution:** personal use with ad-hoc signing (proposed), or Developer ID signing and
  notarisation (needs a paid Apple Developer account).
- **Engine delivery:** installed on first run (proposed: app about 50 MB, about 1 GB download once),
  or bundled in the app (about 1.3 GB app, no download).
- **Minimum macOS:** 14 Sonoma (proposed).
