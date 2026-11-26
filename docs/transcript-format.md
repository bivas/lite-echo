# LiteEcho transcript format (v1) and engine options

This is the contract between the Python engine (`src/liteecho`) and the macOS app (`app/`).

## Transcript HTML

One self-contained file, `<stem>.html`, meant to be read in a browser.

- **Well-formed:** it must parse with a strict XML parser (polyglot HTML: lowercase tags, every
  element closed, attributes quoted, `&amp;` `&lt;` `&gt;` `&quot;` escaped). It starts with
  `<!DOCTYPE html>`, and entities beyond the five XML ones are never used.
- **No scripts:** every page carries
  `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'" />`.
  Styling is a single inline `<style>` block.
- **Escaping:** every piece of text from the transcript, a speaker name, the file name or the audio
  path is HTML-escaped when it is written out.
- **`<html>`:** `<html lang="{code}" dir="rtl|ltr">`. Hebrew, Arabic, Persian, Urdu and Yiddish
  get `rtl`; Auto uses the detected language.

**Metadata** sits in `<head>` as meta tags. The app reads them.

```
<meta name="generator" content="LiteEcho {version}" />
<meta name="liteecho:format" content="1" />
<meta name="liteecho:audio" content="{absolute audio path}" />
<meta name="liteecho:language" content="{code}" />          detected or chosen
<meta name="liteecho:language-mode" content="auto|fixed" />
<meta name="liteecho:speakers" content="{count found}" />
<meta name="liteecho:speakers-mode" content="auto|exact:N|range:MIN-MAX" />
<meta name="liteecho:duration-ms" content="{int}" />
<meta name="liteecho:created" content="{ISO-8601 UTC}" />
```

**Body:**

```
<header class="doc">
  <h1>{title}</h1>
  <p class="info">{audio file name} · {duration} · {language name} · {N} speakers</p>
  <ul class="speakers">
    <li data-speaker="S1"><span class="speaker" data-speaker="S1">S1</span></li>
    ...
  </ul>
</header>
<main>
  <section class="turn" data-speaker="S1" data-start-ms="0" data-end-ms="4210">
    <h2><span class="speaker" data-speaker="S1">S1</span> <time data-ms="0">00:00:00</time></h2>
    <p>Text of the turn. <span class="pause" data-ms="3100">(3 s pause)</span> More text.</p>
  </section>
  ...
</main>
<footer class="doc"><p>Transcribed with LiteEcho {version}</p></footer>
```

- Speaker IDs are `S1`, `S2`, … in order of first appearance. An ID never changes. Only the text
  inside `.speaker` elements is the display name.
- A `turn` is a run of consecutive speech by one speaker. Overlap and very short interjections are
  attributed to the speaker with the largest time overlap.
- Pause marks are added for gaps of 1 s or more inside a turn or between turns.
  - Under 3 s: `(..)`
  - Otherwise: `(N s pause)`, rounded to whole seconds.
- **Colours:** each speaker gets one from a fixed palette of 8, cycling. They are applied through the
  inline `<style>` with `[data-speaker="S1"]` selectors, not inline attributes.

## Renaming speakers

`liteecho rename-speakers FILE --map S1=Dana --map S2=Avi [--events jsonl]`

- The key is the speaker **ID**.
- The value is the new display name. It is trimmed and limited to 60 characters; control characters
  and `< > " &` are removed, and the result is escaped.
- It rewrites the text of every `.speaker[data-speaker=ID]` and replaces the file atomically. It fails
  with a clear error on a file without `liteecho:format`.

## Engine options

- `--language auto|CODE`: CODE is any of the 100 Whisper language codes. `engine-info --json` adds
  `"languages": [{"code":"he","name":"Hebrew","native":"עברית","tuned":true}, ...]`, sorted by
  `name`. `tuned` means LiteEcho ships a prompt for that language.
- `--speakers auto|N` (N exact).
- `--min-speakers MIN --max-speakers MAX`: a range, with 1 ≤ MIN ≤ MAX ≤ 20. It can't be combined
  with an exact N. Either bound may be given alone.
- JSONL events are unchanged (`stage`, `speakers`, `language`, `done`, `error`).

## App presets (speaker selection, design board 9 · B)

| Preset | Engine arguments |
|---|---|
| Auto | `--speakers auto` |
| Solo | `--speakers 1` |
| Conversation | `--speakers 2` |
| Meeting | `--min-speakers 3 --max-speakers 8` |
| Custom | exact N (1–20) or a range |

## Voice Memos (contract v1)

The engine reads Apple's Voice Memos library **read-only**, through a private copy of its database.
The app talks to it only through these commands.

### `liteecho voice-memos list --json [--library DIR]`

The default `--library` is `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`.
It prints one JSON object to stdout and always exits 0 when it could answer, including when access is
denied:

```json
{"status": "ok" | "no-access" | "no-library" | "unreadable",
 "detail": "human-readable reason (no recording data)",
 "folders": [{"id": "<uuid>", "name": "Work"}],
 "memos": [{
   "id": "<ZUNIQUEID>",            // stable, the dedupe key
   "title": "Customer call",        // never empty; falls back to "New Recording" style label
   "recorded": "2026-11-26T08:42:00Z",
   "duration_s": 1311.4,
   "folder_id": "<uuid>" | null,
   "favorite": true,
   "local": true,                   // audio file present on this Mac
   "apple_transcript": false,       // best effort; false when unknown
   "format": "m4a" | "qta"
 }]}
```

- **Excluded:** memos in Recently Deleted and memos still being recorded.
- **Order:** newest first.
- **Status `no-access`:** the library exists but reading it is denied (EPERM), so Full Disk Access is
  needed.
- **Status `no-library`:** the library does not exist (ENOENT).

### `liteecho voice-memos import ID [--output-folder DIR] [transcribe options…] [--events jsonl]`

- It runs one transcription of the memo with that ID, using the normal transcribe options
  (`--language`, `--speakers`, `--min-speakers` and `--max-speakers`).
- The audio is copied to a temporary file first; Apple's files are never opened for writing.
- The output file is `<output-folder>/<sanitised title> (<YYYY-MM-DD HHMM>).html`. The default output
  folder is `~/Documents/LiteEcho Transcripts`.
- Events are the same as transcribe.
- Errors arrive as an `error` event with `detail` set to one of these codes, and the exit code is 1:
  - `no-access`: Full Disk Access is needed
  - `not-found`: no memo with that ID, or no library
  - `not-local`: the audio is only in iCloud, or its path is unsafe
  - `unreadable`: the database copy is corrupt or its layout is unknown
  - `unsupported-format`: the audio can't be decoded
- Layered `.qta` memos: only the first audio track is transcribed.

### Extra transcript meta for imported memos

```
<meta name="liteecho:source" content="voice-memos" />
<meta name="liteecho:source-id" content="{memo id}" />
<meta name="liteecho:recorded" content="{ISO-8601 UTC}" />
<meta name="liteecho:source-folder" content="{folder name}" />   (omitted when none)
```

The `<h1>` title is the memo title. The main command also accepts `--title TEXT` to override the
title, which by default is the file stem.
