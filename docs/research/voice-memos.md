# Research: importing recordings from Apple Voice Memos

Status: research only. No app code was changed. Date: 2026-11-26.

**Question.** Can LiteEcho read recordings from Apple's Voice Memos app on macOS, and what metadata comes with them? LiteEcho is a SwiftUI app plus a Python CLI. It is not sandboxed, not on the App Store, and ad-hoc or Developer ID signed.

**Short answer.** Yes, with one condition: the user must grant **Full Disk Access** to LiteEcho (and to their terminal app if they use the CLI). Voice Memos keeps its library in a protected app group container. Inside it are an undocumented Core Data SQLite database (`CloudRecordings.db`) and the audio files (`.m4a` or `.qta`). From those, LiteEcho can show title, date, duration, folder, favourite, Recently Deleted state, and whether Apple has already made a transcript. Apple's own transcripts are stored inside the audio file. There is no public API.

Two routes need no extra permission:
- the user picks a memo through the system open panel (`NSOpenPanel` or `fileImporter`);
- the user drags a memo out of Voice Memos onto LiteEcho.

These routes give LiteEcho only the audio file, not the database metadata.

Legend used below:
- **[local]** was checked on this Mac.
- **[source]** comes from the cited web or code sources.
- **[inferred]** is my own reasoning.

---

## 0. Local environment and evidence [local]

The checks were limited to the schema and to permissions. No titles, paths, transcripts or row values were read, and no audio was copied.

| Check | Result |
|---|---|
| OS | `sw_vers`: macOS **27.2.1** (build 26B131). The kernel is Darwin 27.2.0, so this is newer than Tahoe 26. |
| Voice Memos app | `/System/Applications/VoiceMemos.app`, `CFBundleShortVersionString` = **4.0** |
| App entitlements (`codesign -d --entitlements -`) | `com.apple.security.app-sandbox`; `com.apple.security.application-groups` = `group.com.apple.VoiceMemos.shared` (+ `group.com.apple.tipsnext`); `com.apple.private.security.restricted-application-groups` = `group.com.apple.VoiceMemos.shared`; `keychain-access-groups` = the same group |
| `~/Library/Group Containers/group.com.apple.VoiceMemos.shared` | Exists (`drwx------`). `stat` works, but `ls` fails with **"Operation not permitted"** |
| `.../Recordings/` | `stat` works (`drwxr-xr-x`, with a link count showing it is not empty). Listing it fails: **EPERM, "Operation not permitted"** |
| `.../Recordings/CloudRecordings.db`, `-wal`, `-shm` | All three exist and `stat` works. Sizes: about 0.5 MB DB, about 2 MB WAL, 32 KB SHM. **The DB runs in WAL mode.** |
| `sqlite3 -readonly "file:...CloudRecordings.db?mode=ro" .tables` | **`Error: unable to open database ...: authorization denied`** |
| Python `os.path.exists(db)` / `os.access(db, R_OK)` / `open(db)` | `True` / **`False`** / **`EPERM (errno 1)`** |
| `~/Library/Containers/com.apple.VoiceMemos/Data` | `ls` fails with "Operation not permitted" |
| `~/Library/Application Support/com.apple.voicememos` | Does not exist. This was the pre-Catalina/Big Sur legacy location. |
| Process context | The checks ran under the Claude Code agent binary, which does **not** have Full Disk Access. That is why every read was denied. |

**Conclusion [local].** TCC blocks every read of the container's contents. The block covers listing directories, `open(2)` and SQLite open. File metadata through `stat` and `exists` still works. As a result, **the DB schema and row counts could not be read on this machine.** The schema in §1 comes from the sources. To verify it locally, grant Full Disk Access to Terminal and run the following, which prints only the schema and counts:

```sh
DB="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db"
sqlite3 -readonly "file:$DB?mode=ro" '.schema ZCLOUDRECORDING' '.schema ZFOLDER' \
  'SELECT COUNT(*) FROM ZCLOUDRECORDING;' 'SELECT COUNT(*) FROM ZFOLDER;'
```

This gives a clean detection signal:
- `exists == true`, `access(R_OK) == false` and errno `EPERM` together mean "library present, permission missing".
- `ENOENT` means "no library". Voice Memos was never opened, or the user has no recordings.

### App Intents / Shortcuts surface [local]

I parsed `VoiceMemos.app/Contents/Resources/Metadata.appintents/extract.actionsdata`.

- **Actions:** Record, Stop, Toggle Recording, Play, Search Recordings, Select/Open Recording, Open/Create/Delete Folder, Delete Recording, Combine Recordings, Import Recording (`audioFile`, `title`), and Change Playback Setting.
- **Entities:**
  - `RCRecordingEntity`: properties `name`, `creationDate`, `duration`. It is indexed, syncable, an assistant entity, and "structured data representable".
  - `RCFolderEntity`: properties `name`, `recordingCount`.

No action returns the audio file or the transcript. There is no AppleScript dictionary: `NSAppleScriptEnabled` is absent and there is no `.sdef`. Shortcuts is therefore **not a useful way to get audio out of Voice Memos.** At most, a user shortcut could list names, dates and durations. Whether "Search Recordings" output can be turned into a file through a Shortcuts "Get File" step is **unverified**, and I think it is unlikely. This is also unchanged: Voice Memos offers *Import Recording*, but nothing that exports one.

---

## 1. Storage layout

### Paths by macOS version [source + local]

| macOS | Library folder | Notes |
|---|---|---|
| ≤ 10.14 / early 11 | `~/Library/Application Support/com.apple.voicememos/Recordings/` | Legacy location. Some tools still fall back to it (gloamy reference doc). It is absent here [local]. |
| 12 Monterey → 15 Sequoia → 26 Tahoe → 27 | `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/` | Confirmed on this Mac (27.2.1) [local]. jwulff/apple-voice-memo-mcp (Sonoma+), island-io/mila, the flaviocopes exporter and the Apple forum thread 768040 all use this path [source]. |

Contents of `Recordings/`:
- `CloudRecordings.db`, plus `-wal` and `-shm`. This is the Core Data store, backed by NSPersistentCloudKitContainer according to a third-party skill (unverified).
- Audio files named like `YYYYMMDD HHMMSS-XXXXXXXX.m4a`, where the suffix is the first 8 characters of `ZUNIQUEID`.
- `.qta` files for layered and spatial recordings.
- `<file>.composition/` folders, which hold edit state for edited recordings. These are not recordings in their own right (OpenExtract doc).

A very old schema used `Recordings.db` with a `ZRECORDING` table. Tools such as exVMs and OpenExtract still support it as a fallback.

### `ZCLOUDRECORDING` columns (one row per memo) [source]

The columns are compiled from several independent implementations:
- jwulff/apple-voice-memo-mcp `voice-memo-db.ts`
- island-io/mila `VoiceMemosLibrary.swift`
- iXerol/exVMs `db.rs`
- iBz-04/gloamy `voice-memos-data.md`
- charleswest775/openextract `VOICE_MEMOS_EXTRACTION.md`, which is derived from Apple's iOS 26.5 Core Data model but has not been checked against a real library
- esaruoho/apple `voice-memos-tsrp-atom.md`, observed on macOS 15.6.1

| Column | Meaning | Confidence |
|---|---|---|
| `Z_PK` | Core Data row id. Not stable across DB rebuilds. | high |
| `ZUNIQUEID` | Recording UUID, stable and synced. Use it as LiteEcho's dedupe key. | high |
| `ZDATE` | Recording date as Core Data time (seconds since 2001-01-01 UTC). Convert with `ZDATE + 978307200` to get Unix time. | high |
| `ZDURATION` | Duration in seconds (float) | high |
| `ZLOCALDURATION` | Duration of the local file. Prefer it when > 0. Its presence together with `ZENCRYPTEDTITLE` marks the "modern" schema (exVMs). | medium |
| `ZPATH` | Audio filename relative to `Recordings/`. Older rows may hold an absolute path, so take the basename. Some schemas have `ZURL` instead (Mila). | high |
| `ZENCRYPTEDTITLE` | User-visible title on macOS 14+ / iOS 17+. Despite the name, it is plaintext locally; it is *encrypted in iCloud* (Apple support 105006, MacRumors). | high |
| `ZCUSTOMLABEL` | Older title column. On 14+ it can hold a placeholder date string, so use it as a last resort. | high |
| `ZCUSTOMLABELFORSORTING` | Sort or display title (skillsmp/cathrynlavery, OpenExtract) | medium |
| `ZENCRYPTEDCUSTOMLABEL` | Alternative title column in newer models (OpenExtract) | low–medium |
| `ZFOLDER` | FK to `ZFOLDER.Z_PK`. NULL means unfiled ("All Recordings"). | high |
| `ZEVICTIONDATE` | **Recently Deleted** timestamp. Non-NULL means the memo is in the trash. Despite the name, this is not iCloud eviction (OpenExtract, Mila, exVMs). gloamy calls it `ZTRASHEDDATE`; that name may be version-dependent. | medium–high |
| `ZFLAGS` | Bitfield. Reported bits: `0x02` = in iCloud only, not downloaded (OpenExtract, iOS); `0x04` always set on synced recordings (esaruoho); `0x40` = recorded on Watch; `0x800` = layered; `0x1000` = spatial. **"Has transcript" is reported as `0x08` by esaruoho (macOS 15.6.1, 13 recordings observed) but as `0x400` by OpenExtract (iOS 26.5 model).** The two sources conflict, so verify locally or just probe the file. | low–medium |
| `ZSHAREDFLAGS` | Bitfield: bit `0x02` = favourite, `0x04` = enhanced recording (OpenExtract) | low–medium |
| Location | Older Voice Memos could name a recording after its location, which became the title. I found no dedicated location column in the sources. Treat location as **not available**. | unverified |

### `ZFOLDER` [source]

| Column | Meaning |
|---|---|
| `Z_PK` | Row id that `ZCLOUDRECORDING.ZFOLDER` points to |
| `ZUUID` | Stable folder id that survives renames. Use it as the persisted key (Mila). |
| `ZENCRYPTEDNAME` | Folder name on 14+. Older schemas use `ZNAME`. |
| `ZRANK` | Sort order |
| `ZNUMBEROFCONTAINEDRECORDINGS` | Present on some schemas only (Mila) |

Smart folders (All Recordings, Favourites, Recently Deleted, Watch) are not rows in this table. They are derived from the flags and dates above.

**Schema stability.** The schema is private and has drifted across versions: renamed title columns, `ZPATH`/`ZURL`, `ZEVICTIONDATE`/`ZTRASHEDDATE`. Every mature implementation reads `PRAGMA table_info` first and picks the first column that exists (Mila `firstPresent`, exVMs `optional_column_expr`). LiteEcho should do the same.

### Recently Deleted

Deleted memos stay in the DB with `ZEVICTIONDATE` set, and their audio stays on disk for about 30 days. Exclude them by default with `WHERE ZEVICTIONDATE IS NULL`. Optionally offer a "Show recently deleted" toggle.

### iCloud sync behaviour [source + inferred]

- When "Voice Memos" is enabled in iCloud settings, the Mac's library includes memos recorded on iPhone, iPad and Watch. The DB row usually arrives before the audio.
- A row may have **no local audio file**. Possible causes are a download not yet finished, or iCloud-only state (`ZFLAGS & 0x02` on iOS; unverified on macOS). In my experience the Mac app downloads audio on demand when a memo is played. LiteEcho must check that the file exists and show "Not downloaded — open it in Voice Memos first".
- Titles are encrypted in iCloud from iOS 17 / macOS 14. If devices run mixed OS versions, titles can show as dates (Apple support 105006). This affects only what LiteEcho reads, not how it reads it.
- Some tools (jwulff) say a missing DB may mean iCloud sync is off. In fact a purely local library also has a DB [inferred]. The local DB is created the first time Voice Memos is opened.

### File formats [source]

- **`.m4a`**: AAC by default, or Apple Lossless (ALAC) when Settings › Voice Memos › Audio Quality is set to Lossless. Both decode with AVFoundation and ffmpeg, so they are fine for LiteEcho's pipeline.
- **`.qta`** (QuickTime Audio): used for **layered recordings**, which can be created on iPhone 16 Pro (iOS 18.2) and played on macOS 15.2+ (Apple Newsroom, MacRumors), and for spatial recordings. The file is a multi-track QuickTime container. AVFoundation should open it. ffmpeg will probably demux it as `mov`, but it may pick only one track. LiteEcho should mix down or choose the right track. This is **unverified.**
- **`.composition/` folders**: hold edit state for trimmed or replaced recordings. Read only the main file that `ZPATH` names.
- **Enhanced recordings**: the "Enhance" toggle is a flag (`ZSHAREDFLAGS & 0x04`, low confidence). In my understanding the file is the original and enhancement is applied at playback, but this is **unverified**. LiteEcho should transcribe the raw file.

### Apple-generated transcripts (macOS 15+, iOS 18+) [source]

- Voice Memos on macOS 15+ shows transcripts (Apple support vm4a03609f0d). Memos from macOS 14 or earlier get transcribed **when opened** in the app. The feature is not available in every region. Third-party testing (esaruoho, macOS 15.6.1) found it effectively English-only and poor on mixed-language speech.
- **The transcripts are not in the DB.** They are written into the audio file:
  - **`.m4a`:** a `tsrp` atom at `moov/trak/udta/tsrp`. The Thomascountz gist says `moov/trak/mdia/udta`; the path was observed, not documented. In practice the atom sits near the end of the file.
  - **`.qta`:** a `com.apple.VoiceMemos.tsrp` metadata item (OpenExtract).
- The payload is UTF-8 JSON: `{"locale": …, "attributedString": {"runs": [text, attrIdx, text, attrIdx, …], "attributeTable": [{"timeRange": [start, end]}, …]}}`. Joining the even-indexed `runs` entries gives the full text. Each attribute index gives that fragment's time range, so segment-level timestamps are possible (esaruoho, OpenExtract, Thomascountz gist).
- **To detect one**, use the `ZFLAGS` bit, whose meaning is disputed (§1 table), or simply scan the file's atoms for `tsrp`. The atom scan is cheap: read the box headers only, not the audio.

---

## 2. Access and permissions

### What protects the container

- Every App Group container is protected from apps outside the group since macOS 15 (Sequoia), including for non-sandboxed apps (Apple doc "Protecting local app data using containers"; forum 756701).
- On top of that, Apple DTS describes the Voice Memos container as protected by **MAC (Mandatory Access Control)** as highly sensitive data (forum thread 768040). The `restricted-application-groups` entitlement found locally fits that description [local].
- On macOS 14 this container was already TCC-protected. Sonoma tools such as jwulff and the flaviocopes exporter already needed Full Disk Access [source].
- There is no per-folder prompt for it. Unlike Desktop or Documents, nothing appears under "Files & Folders" that would cover it. The usable grants are **Full Disk Access** and the **open panel** (below).

### Full Disk Access (the main path)

- The user adds **LiteEcho.app** under System Settings › Privacy & Security › Full Disk Access. jwulff, Mila and the flaviocopes exporter all confirm FDA unblocks this container [source]. I could not verify it locally because I could not grant FDA to the agent.
- **The CLI:** TCC applies to the *responsible process*. For `liteecho` run from Terminal or iTerm, that is the terminal app, so the **terminal app needs FDA**. A CLI launched *by* LiteEcho.app as a subprocess inherits the app's grant, because the app is the responsible process.
- **Signing matters.** TCC keys grants on the code-signing identity.
  - With a **Developer ID**-signed build, the grant survives updates.
  - With an **ad-hoc**-signed build, the designated requirement is the cdhash, so **every rebuild loses the grant**. The user has to remove and re-add the app, or run `tccutil reset SystemPolicyAllFiles <bundle id>`. This is worth documenting for dev builds.
- **Detecting a missing grant.** There is no public API (forum 114452; FB13511819). Use this pattern, which Mila also uses:
  1. `fileExists(db)`. If false, show "No Voice Memos library (open Voice Memos once)".
  2. `access(db, R_OK) != 0` with errno `EPERM` or `EACCES` means "Permission needed". Verified locally: `exists` returns true, `access` returns false, `open` gives EPERM.
  3. Otherwise open the DB. A SQLite error "authorization denied" also means permission is missing [local].
  4. Re-check when the app becomes active (`NSApplication.didBecomeActiveNotification`), because the user grants FDA in another app. Note that a new FDA grant often does not apply until the app restarts, so offer a "Relaunch LiteEcho" button.
- **Opening the settings pane:** `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, via `NSWorkspace.shared.open(URL(string: …)!)`. This is the documented anchor.
  - **Caveat:** a developer forum report says that on **macOS 27.3** this URL lands only on the top level of Privacy & Security. Apple DTS calls that a bug (forum 858112; FB25625724).
  - So the UI text must also say: "Privacy & Security › Full Disk Access › + › choose LiteEcho". Optionally offer "Reveal LiteEcho in Finder" so the user can drag the app into the list.
  - There is no programmatic "request FDA" prompt. The app cannot add itself.

### No-permission alternatives

1. **Open panel: `NSOpenPanel` / SwiftUI `.fileImporter`.** Apple DTS confirmed that an unsandboxed app **can read a Voice Memos file the user picks through the open panel**, because the panel runs out of process and extends access to the chosen file (forum 768040). Set `directoryURL` to the Recordings folder, so the user doesn't need ⌘⇧G into a hidden Library folder.
   - This route gives the audio file only: no DB, so no title, folder or favourite. The filename's date and the file's own metadata are still available, and so is the embedded `tsrp` transcript.
   - Whether *selecting the `Recordings` folder itself* grants folder-wide access, which would also open the DB, is **unverified**. MAC restrictions may still block it. This is worth one experiment.
2. **Drag and drop from Voice Memos.** Dragging a memo out of the Voice Memos list onto LiteEcho's drop zone provides a file promise or exported file.
   - Users report that layered memos sometimes arrive as `.qta` (Apple community thread 256214860). LiteEcho must accept `public.audio`, `com.apple.quicktime-audio` (the UTI is declared in VoiceMemos' Info.plist [local]) and `com.apple.m4a-audio`. It must also handle `NSFilePromiseReceiver`, not only file URLs.
   - Metadata arrives only through the dropped filename. Voice Memos usually names the exported file after the memo title, so that can seed the transcript title [inferred]. Date and duration come from the file.
3. **Share › Save to Files / File › Export** in Voice Memos, then import the file normally. This route has the most friction.
4. **Shortcuts / AppleScript: not viable** for audio (§0).

---

## 3. Safe integration design

### Reading the DB without touching Apple's data

- **Never write.** Open read-only, never run `VACUUM` or migrations, and never touch `-wal` or `-shm` with write access. Voice Memos and `cloudd` write to the DB concurrently.
- **Do not use `immutable=1` on the live DB.** The local DB is in WAL mode, with a 2 MB `-wal` against a 0.5 MB main file [local]. `immutable=1` makes SQLite **ignore the WAL**, so recently added or renamed memos would be missing or stale. On a DB that changes underneath the reader, it can even return corrupt-looking results.
- Recommended, in order:
  1. **Copy, then read (most robust):** copy `CloudRecordings.db`, `-wal` and `-shm` together into a temp dir in LiteEcho's container (`FileManager.copyItem` or `clonefile`). Open the copy normally, which checkpoints the copied WAL into the copy only. Then run `PRAGMA quick_check`. If it fails, which can happen when a copy catches a write mid-flight, retry after a short delay. Apple's files are never locked or modified.
  2. **Live read-only:** `sqlite3_open_v2(path, SQLITE_OPEN_READONLY)` or the URI `file:…?mode=ro`. This reads the WAL correctly. It may need the `-shm` to exist, which it does [local]. A reader holds only a shared lock, so the risk to Apple's writes is small, but a long-running read can stall WAL checkpoints. Keep the transaction short: open, query, close (Mila's pattern).
  - Mila warns against `file:` URIs here because the path contains spaces and could contain `?` or `#`. Either pass the literal path with `SQLITE_OPEN_READONLY`, or percent-encode the path if you use a URI. In Python, use `sqlite3.connect(f"file:{urllib.parse.quote(path)}?mode=ro", uri=True)`.
- **Probe the schema** with `PRAGMA table_info(ZCLOUDRECORDING)` and `PRAGMA table_info(ZFOLDER)`. Choose columns by presence and degrade gracefully when one is missing.
- **Audio:** read it in place, or copy it into LiteEcho's working dir before transcription, so a long transcription job doesn't hold a handle on a file Voice Memos might replace. Read only the file named by `ZPATH`, never the `.composition/` contents.

### Query sketch (adapt to the columns present)

```sql
SELECT r.ZUNIQUEID, r.ZDATE, COALESCE(NULLIF(r.ZLOCALDURATION,0), r.ZDURATION) AS dur,
       COALESCE(r.ZENCRYPTEDTITLE, r.ZCUSTOMLABEL) AS title, r.ZPATH,
       f.ZUUID AS folder_id, f.ZENCRYPTEDNAME AS folder_name,
       r.ZFLAGS, r.ZSHAREDFLAGS, r.ZEVICTIONDATE
FROM ZCLOUDRECORDING r LEFT JOIN ZFOLDER f ON f.Z_PK = r.ZFOLDER
WHERE r.ZEVICTIONDATE IS NULL
ORDER BY r.ZDATE DESC;
```

### Watching for new memos ("auto-import")

- **FSEvents** on `…/Recordings/`, using `FSEventStreamCreate` or a `DispatchSource` on the directory. Debounce for about 2 s. Changes to `CloudRecordings.db-wal` signal DB updates, and new `.m4a`/`.qta` files signal new audio.
  - This needs Full Disk Access. Without it, I expect no events or no useful paths [inferred; unverified].
- After each event, re-query (via copy-then-read) and diff by `ZUNIQUEID` against LiteEcho's "already imported" set.
- **Don't auto-import too eagerly:**
  - Wait until the memo is finished. A recording in progress has a growing file and may already have a row.
  - Wait until the audio exists locally. Treat it as stable when the file size is unchanged for N seconds and `ZDURATION` > 0.
  - Skip memos that are in Recently Deleted.
- Optionally limit auto-import to one user-chosen Voice Memos folder (stored by `ZFOLDER.ZUUID`) or to memos newer than when the feature was enabled. This avoids importing years of backlog at once.
- A polling fallback, such as re-checking every N minutes or when the app becomes active, is simpler and good enough for v1.

### Mapping into LiteEcho

| LiteEcho field | Voice Memos source |
|---|---|
| Transcript title | `ZENCRYPTEDTITLE` → `ZCUSTOMLABELFORSORTING` → `ZCUSTOMLABEL` (if it's not just a date) → the filename |
| Recorded at | `ZDATE + 978307200` (Unix seconds, UTC). Show it in local time. |
| Duration | `ZLOCALDURATION` if > 0, else `ZDURATION` |
| Source / origin | `voice-memos`, plus `ZUNIQUEID` as an external id for dedupe and "already imported" badges |
| Folder / tag | `ZFOLDER.ZENCRYPTEDNAME` (key: `ZUUID`) |
| Favourite | `ZSHAREDFLAGS & 0x02` (verify locally) |
| Audio file | `Recordings/<basename(ZPATH)>`, which can be `.m4a` or `.qta` |
| Apple transcript (optional) | the `tsrp` atom. Could be offered as a "compare" or quick preview, but LiteEcho's own model will be better, especially for languages other than English. |
| Recorded on Watch / layered / spatial | `ZFLAGS` bits (low confidence). Use them only for display or as hints for handling `.qta`. |

Privacy: everything stays local. Titles and transcripts are personal data, so don't log titles or paths by default.

---

## 4. Recommendation

**It is feasible, at moderate effort.** The work is a read-only SQLite reader, a permission flow and an import sheet, roughly **2–4 days** for v1, plus about 1 day for auto-import. The main risks:
- The schema is private and drifts between versions.
- Full Disk Access is a big ask of users.
- The FDA deep link is broken on macOS 27.3.
- Ad-hoc-signed builds lose the FDA grant on every rebuild.
- `.qta` layered files need a mix-down or track choice.

Proposed UX:
1. **File › Import from Voice Memos…** opens a sheet.
   - **If permission is missing:** an explainer ("Voice Memos keeps recordings in a protected folder. LiteEcho needs Full Disk Access to list them. Nothing is modified."), an "Open System Settings" button (deep link plus written steps), a "Relaunch LiteEcho" button, and a link to the alternative "Choose a file instead…" (the open panel aimed at the Recordings folder).
   - **If the library is readable:** a searchable list showing **title, date, duration and folder**, with a favourite star, "Not downloaded" and "Already imported" badges, and an "Apple transcript available" indicator. A folder filter sits in a sidebar or popup. The user multi-selects, then clicks **Import**, and LiteEcho copies each audio file and queues transcription with the title and date pre-filled.
2. **Fallback that needs no permission:** the existing drop zone accepts memos dragged from Voice Memos, including file promises and `.qta`. The open panel route also works. Either way the title comes from the filename and the date and duration from the file.
3. **CLI:** `liteecho voice-memos list|import <unique-id>…` with the same read-only reader. If it gets EPERM, it prints "Grant Full Disk Access to your terminal app (Terminal/iTerm) in System Settings › Privacy & Security › Full Disk Access".
4. **Later:** an opt-in "Auto-import new Voice Memos" setting (FSEvents or polling, optionally scoped to one folder).

**Before building, verify on a Mac with Full Disk Access granted to Terminal:**
- the schema and counts, with the command in §0;
- the `ZFLAGS` transcript bit (`0x08` vs `0x400`);
- the `ZSHAREDFLAGS` favourite bit;
- the `ZEVICTIONDATE` vs `ZTRASHEDDATE` name;
- whether picking the `Recordings` folder in an open panel grants folder-wide access;
- whether `.qta` decodes in LiteEcho's pipeline.

### Metadata fields LiteEcho could use

- `ZUNIQUEID`: stable id, used for dedupe
- Title: `ZENCRYPTEDTITLE` / `ZCUSTOMLABEL` / `ZCUSTOMLABELFORSORTING`
- `ZDATE`: recording timestamp
- `ZDURATION` / `ZLOCALDURATION`
- `ZPATH`: audio file (`.m4a` AAC/ALAC, `.qta` layered or spatial)
- Folder: `ZFOLDER` → `ZFOLDER.ZUUID`, `ZENCRYPTEDNAME`, `ZRANK`
- Recently Deleted: `ZEVICTIONDATE`
- Favourite and enhanced: `ZSHAREDFLAGS` bits
- iCloud-only / not downloaded: `ZFLAGS & 0x02` plus a check that the file exists
- Has Apple transcript: a `ZFLAGS` bit (disputed) or the presence of a `tsrp` atom
- Recorded on Watch, layered, spatial: `ZFLAGS` bits (low confidence)
- Apple transcript text, locale and per-segment time ranges: the `tsrp` JSON in the audio file
- Not available: location (no column found), speaker info, and any edit history beyond `.composition/`

---

## Sources

- Apple Developer Forums, Voice Memos container blocked; DTS recommends NSOpenPanel/fileImporter: https://developer.apple.com/forums/thread/768040
- Apple Developer Forums, SIP and app group containers on macOS 15: https://developer.apple.com/forums/thread/756701
- Apple docs, Protecting local app data using containers: https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers
- Apple Developer Forums, reliable test for Full Disk Access: https://developer.apple.com/forums/thread/114452
- Apple Developer Forums, `Privacy_AllFiles` URL broken on macOS 27.3: https://developer.apple.com/forums/thread/858112
- System Settings pane URL list (gist): https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751
- Apple Support, View a transcription in Voice Memos on Mac: https://support.apple.com/guide/voice-memos/vm4a03609f0d/mac
- Apple Support, If your Voice Memos titles changed to dates (title encryption): https://support.apple.com/en-ca/105006
- MacRumors, Voice Memos titles encrypted in iCloud (iOS 17 / Sonoma): https://www.macrumors.com/2023/09/19/apple-voice-memos-titles-encryption/
- Apple Newsroom, Layered recordings (.qta, macOS 15.2): https://www.apple.com/newsroom/2024/12/voice-memos-update-brings-layered-recording-to-iphone-16-pro-lineup
- MacRumors, Layer tracks in Voice Memos: https://www.macrumors.com/how-to/layer-tracks-voice-memos-iphone/
- Apple Community, exporting M4A vs `.qta` from Voice Memos on Mac: https://discussions.apple.com/thread/256214860
- Apple Community, exporting voice memos with titles on Sonoma (SQL on ZCLOUDRECORDING): https://discussions.apple.com/thread/255955065
- jwulff/apple-voice-memo-mcp (FDA requirement, read-only DB, tsrp): https://github.com/jwulff/apple-voice-memo-mcp
- island-io/mila `VoiceMemosLibrary.swift` (EPERM/ENOENT classification, column probing): https://github.com/island-io/mila
- iXerol/exVMs `src/db.rs` (modern vs legacy schema detection): https://github.com/iXerol/exVMs
- charleswest775/openextract `docs/VOICE_MEMOS_EXTRACTION.md` (column and flag map from the iOS 26.5 model; tsrp in m4a/qta): https://github.com/charleswest775/openextract
- esaruoho/apple `wiki/concepts/voice-memos-tsrp-atom.md` (tsrp JSON format; ZFLAGS 0x08 on macOS 15.6.1): https://github.com/esaruoho/apple
- iBz-04/gloamy Voice Memos data reference: https://github.com/iBz-04/gloamy
- Thomascountz tsrp extractor gist: https://gist.github.com/Thomascountz/b84b68f0a7c6f2f851ebc5db152b676a
- cathrynlavery voice-memo-organizer (ZCUSTOMLABELFORSORTING; Tahoe sync note): https://github.com/cathrynlavery/voice-memo-organizer
- abrignoni/iLEAPP Voice Recordings artifact parser: https://github.com/abrignoni/iLEAPP
- Eclectic Light, privacy protection overview: https://eclecticlight.co/2025/03/12/why-all-this-privacy-protection-an-overview/
