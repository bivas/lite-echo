# Developing LiteEcho

Notes for building, testing and releasing LiteEcho. For using it, see the [README](README.md).

## Requirements

- macOS 14+ on Apple Silicon (arm64)
- The Xcode Command Line Tools (full Xcode works too)
- [uv](https://docs.astral.sh/uv/)

## Layout

| Path | What it holds |
|---|---|
| `src/liteecho/` | The Python engine and the `liteecho` CLI (faster-whisper + pyannote) |
| `app/` | The SwiftUI app, a Swift package. Modules: `LiteEchoCore`, `LiteEchoShared`, `LiteEchoQueue`, `LiteEchoSetup`, `LiteEchoApp`, plus the `LiteEchoSnapshots` screenshot tool |
| `scripts/` | Build, test, DMG, icon and screenshot scripts |
| `docs/transcript-format.md` | The contract between the engine and the app: the HTML format and the engine options |

## Building the app

```bash
scripts/build-app.sh          # → build/LiteEcho.app (add --debug for a faster build)
scripts/test-app.sh           # Swift tests
```

**What the build does:** `build-app.sh` builds the engine wheel and bundles it into
`LiteEcho.app/Contents/Resources/engine`, together with `uv` and the pinned `requirements.txt`. On first
launch the app builds its engine venv from those.

**Options:**

- The version comes from `pyproject.toml`. To override it, set `LITEECHO_VERSION` or pass `--version X`.
- With `MACOS_SIGN_IDENTITY` set, it signs with that identity and the hardened runtime; otherwise it
  signs ad-hoc.

Without Xcode, SwiftUI's `@State` and `@Entry` macros don't compile. Use `@StateVar`
(`LiteEchoShared/Compat.swift`) and classic `EnvironmentKey`s.

### Assets

- **App icon:** drawn by `scripts/make-icon.swift`.

  ```bash
  swift scripts/make-icon.swift /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o app/Assets/AppIcon.icns
  ```

- **README screenshots:** rendered off-screen from the real SwiftUI views with sample data. No screen
  recording permission is needed, and they are written to `docs/screenshots/`:

  ```bash
  scripts/screenshots.sh                  # all screens
  scripts/screenshots.sh menubar-panel    # just one
  ```

## Tests

[`.github/workflows/test.yml`](.github/workflows/test.yml) runs the Python and Swift unit tests on
every push to `main` and every pull request.

```bash
uv run pytest                  # unit tests
uv run pytest -m integration   # end-to-end regression on a real recording
scripts/test-app.sh            # Swift tests
```

**The regression test:**

- **What it compares:** it transcribes `$LITEECHO_REFERENCE_DIR/<stem>.m4a` and compares the speaker
  turns and text with an expected transcript in `$LITEECHO_EXPECTED_DIR`. By default that is
  `tests/.expected/`, which is git-ignored.
- **Creating the reference:** run the test once with `LITEECHO_UPDATE_EXPECTED=1`.

**Random sampling:** when whisper is unsure about a passage, it falls back to random sampling at higher
temperatures. That text can differ between runs, and a seed doesn't help, because ctranslate2 samples on
its own threads. So the test ignores everything from the first sampled segment onwards, which the CLI
reports through the hidden `--sampled-report` flag. The test fails if that would hide more than 5% of
the turns.

**Pinned versions:**

- faster-whisper 1.2.1, ctranslate2 4.8.2, pyannote.audio 4.0.7 and torch 2.13.0
- `av==18.1.0`: newer PyAV decodes AAC to slightly different samples, which changes output in
  near-silence. Note that PyPI lists 18.1.0 as yanked over a decoding bug with custom channel layouts.
- Whisper runs with float weights (`compute_type="float32"`) and 3 CPU threads.

## Releases

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs on a `v*` tag, or by hand
(workflow_dispatch).

**What it does:** it builds the app and the DMG, then creates a **draft** GitHub Release with the DMG,
the zip and their checksums. The tag must match `version` in `pyproject.toml`.

```bash
git tag v0.3.0 && git push origin v0.3.0
```

**Signing:** without secrets, the build is ad-hoc signed, so users have to click **Open Anyway** once.
With these repository secrets it is signed with a Developer ID and notarized:

- Signing: `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`
- Notarization: `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

### Building the DMG locally

```bash
scripts/build-app.sh && scripts/make-dmg.sh   # → build/LiteEcho-<version>.dmg, .zip and .sha256
```

**The DMG window:** `make-dmg.sh` draws the background with `scripts/make-dmg-background.swift` and lays
out the window with Finder. If the Finder step fails, it falls back to a plain DMG. Set
`LITEECHO_DMG_PLAIN=1` to skip the layout.

## Research

- [Importing from Voice Memos](docs/research/voice-memos.md): it is feasible, but needs Full Disk
  Access. The note covers which metadata is available.
