# Scribe

**Be in the meeting. Leave with a plan.**

Scribe turns your calls into live transcripts, clear summaries, and todos you can act on. A native macOS app that captures both sides of the conversation—without sending a bot into the call.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/1-live-meeting-dark.png">
  <img src="docs/screenshots/1-live-meeting.png" alt="Scribe transcribing a roadmap review live, with separate Me and Them text and a timestamped note" width="1280">
</picture>

**No meeting bot. On-device transcription. Follow-up built in.**

[Features](#from-conversation-to-next-steps) · [Get started](#get-started) · [Privacy](#your-audio-stays-in-the-moment) · [Development](#develop)

## From conversation to next steps

### Stay in the conversation

Let the live transcript keep track while you listen. Scribe captures your microphone and the meeting's system audio as separate **Me** and **Them** tracks. Add a note without losing your place, or ask “What did they just say?” to catch up without interrupting.

### Keep the context, not just the note

A short note is more useful when you know what led to it. Scribe anchors notes to the transcript and highlights the surrounding discussion when you select one. Flag the risks and details you want the summary to carry forward.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/3-note-highlight-dark.png">
  <img src="docs/screenshots/3-note-highlight.png" alt="A flagged budget note selected beside the highlighted transcript passages that give it context" loading="lazy" width="1280">
</picture>

### End the call with something useful

Turn the discussion into an overview, decisions, action items, and open questions. Keep flagged concerns visible, then copy the summary as Markdown for your team or project notes.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/2-summary-dark.png">
  <img src="docs/screenshots/2-summary.png" alt="A vendor-call summary with decisions, action items, an open question, and a flagged staffing risk" loading="lazy" width="1280">
</picture>

### Turn “I'll do that” into a todo

Meeting action items flow into a standalone task list, alongside anything you add yourself. Set owners and due dates, focus on **Today**, and open the source meeting when you need context. Your edits and completed tasks stay yours—even when you regenerate a summary.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/7-todos-dark.png">
  <img src="docs/screenshots/7-todos.png" alt="Todos showing a personal task and imported meeting actions, with owners, a due date, and source-meeting links" loading="lazy" width="1280">
</picture>

### Ask your meetings, not your memory

“What did we decide about billing?” Ask across saved transcripts, notes, and summaries. Get an answer with citations and source quotes, then open the original meeting to check the details. Library questions search your saved text, not the web.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/6-ask-meetings-dark.png">
  <img src="docs/screenshots/6-ask-meetings.png" alt="Ask your meetings answering a billing question with numbered citations and expandable source quotes" loading="lazy" width="1280">
</picture>

### Give every meeting a home

Keep vendor calls, product reviews, and 1:1s together with folders and tags. Your transcripts, notes, summaries, and linked tasks stay connected after the call ends.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/5-library-dark.png">
  <img src="docs/screenshots/5-library.png" alt="The meeting library organized with Product, Vendors, and 1:1s folders, plus topic tags" loading="lazy" width="1280">
</picture>

*Screenshots show the real app with demo data. Light and dark versions follow your display preference.*

## Your audio stays in the moment

- **Transcribe on your Mac.** Choose Apple SpeechAnalyzer, WhisperKit, or Cohere Transcribe. Cohere runs through native MLX—no Python or local server. Downloaded Cohere models can transcribe offline.
- **Keep the useful text, not an audio archive.** New meetings save transcripts, notes, and summaries, not audio files.
- **Choose your AI provider.** Q&A and summaries use your configured Anthropic or OpenAI-compatible provider. These features send text context to that provider; on-device transcription does not make every AI feature offline.
- **Keep your library local.** Meeting text and todos are stored in SQLite on your Mac. Cross-meeting questions send matching excerpts and conversation context to your AI provider.

Always get any consent required before capturing a meeting.

## Get started

Scribe is **alpha software**. Build it from source with the [development instructions](#develop) below.

- **macOS 14.2+** for system audio capture. Apple SpeechAnalyzer requires **macOS 26**.
- **Apple Silicon** for Cohere Transcribe. Building that provider requires **Swift 6.3+** and Xcode's Metal toolchain; see [Local Cohere Transcribe](#local-cohere-transcribe).
- Allow microphone and system audio access when prompted. Choose your transcription provider in **Settings** and download a model if needed.
- Configure an AI provider for Q&A and summaries, then start **New recording**. Stop capture to get a summary and collect its action items in **Todos**.

<details>
<summary>Architecture and developer tools</summary>

## Layout

```
App/                      thin app target: composition root (AppModel), MenuBarExtra, the main window, views
  Providers.swift         provider registry: one line per transcription/LLM adapter
Packages/ScribeKit/       one SwiftPM target per domain; domains import only Core
  Core/                   models, provider + repository protocols, SessionClock, Broadcaster
  Capture/                MicrophoneSource (AVAudioEngine), SystemAudioSource (process tap + aggregate device), m4a writing
  Detection/              mic-in-use listener, Zoom (CptHost) / Teams / Meet (AX window titles) probes, MicTriggeredMeetingDetector
  Transcription/          Fake, SpeechAnalyzer, WhisperKit, Cohere (MLX); Deepgram / AssemblyAI / OpenAI Realtime are TODO stubs
  Intelligence/           Anthropic (streaming + server web search), OpenAI-compatible, Parallel web search, Jev search gate, QAEngine, LLMSummarizer, prompts
  Notes/                  NotesController, NoteDraft (anchors to when you *start* typing), NoteAnchoring
  Session/                MeetingSession: lifecycle state machine, per-source transcription, persistence fan-out
  Persistence/            GRDB database + repositories, DiskAudioFileStore
  Settings/               AppSettings (UserDefaults), KeychainSecretStore
  Fixtures/               fake audio and an echo LLM for the `scribe` CLI and the app's --ui-testing mode
  Tools/TapCheck/         `scribe-tapcheck` CLI for testing process taps
  Tools/ScribeCLI/        `scribe` dev-debugging CLI: fake meetings, database dumps, search-gate scores, UI driving
project.yml               XcodeGen spec for Scribe.xcodeproj
```

Data flow: each `AudioSource` streams 16 kHz mono `AudioChunk`s into its own `transcribe` call, without a recording file. Mic is "Me" and system audio is "Them", so no diarization is needed. `MeetingSession` merges the segments, broadcasts `SessionEvent`s to the UI and saves final segments. When both tracks are available, signal-based echo detection filters microphone segments explained by delayed speaker audio. Local speech over the other side is retained. The detector is adapted from [Hex](https://github.com/anomalyco/hex); see [third-party notices](THIRD_PARTY_NOTICES.md).

## Develop

```bash
xcodegen generate
```

```bash
open Scribe.xcodeproj
```

```bash
cd Packages/ScribeKit && swift test
```

Run `swift test --sanitize=thread` after touching capture or session code. `CaptureSinkTests` only catches races on the recording file under the thread sanitizer.

Debug builds can render the main screens with demo data, without permissions or API keys. Run the built app binary with `--screenshots <dir>`, for example `build/DerivedData/Build/Products/Debug/Scribe.app/Contents/MacOS/Scribe --screenshots build/screenshots`.

For debugging without the app, `scribe` runs a meeting through the real session, notes, Q&A and summary code with fake audio, transcription and LLM (`demo`), dumps a database (`db`), and scores questions with the Jev search gate (`gate`, which calls the API). See `swift run scribe help <subcommand>`.

```bash
cd Packages/ScribeKit && swift run scribe demo --seconds 12 --note "5:! billing is the main risk" --ask "7:what did they just say?"
```

`scribe ui` drives the real app through the Accessibility API. It launches the Debug build with `--ui-testing`, which swaps in fake audio, the fake transcriber and the echo LLM and keeps its data in a temporary folder. `scribe ui demo` records, takes notes, asks, stops, summarizes and files a meeting, checking each step and the saved database, and exits non-zero on the first failure. Your terminal needs Accessibility access. Build the Debug app first.

```bash
cd Packages/ScribeKit && swift run scribe ui demo
```

The smaller commands (`launch`, `menu`, `press`, `type`, `wait`, `read`, `tree`, `screenshot`, `quit`) can be chained for other flows. Queries match accessibility identifiers such as `notes.add`, titles or labels; `scribe ui tree` lists them.

The app icon (`App/AppIcon.icon`, an Icon Composer document) and the menu bar mark (`ScribeMark` in `App/Assets.xcassets`) are generated from one drawing. After changing the mark, run `swift scripts/make-icons.swift`.

Debug builds sign with your Apple Development certificate (Xcode ▸ Settings ▸ Accounts creates one), so macOS keeps their permissions and Keychain access across rebuilds.

Settings ▸ About shows the version, build number and commit the app was built from. All three come from git: on every build, the "Stamp version" build phase (`scripts/stamp-version.sh`) writes them into the built app's Info.plist.

- **Version.** Semver from the latest `vX.Y.Z` tag. A build from a commit after the tag is the next patch's prerelease: three commits past `v0.2.0` builds as `0.2.1-dev.3`. `CFBundleShortVersionString` is the tag's plain `X.Y.Z`, because macOS only accepts numbers there. The full version is in `ScribeVersion`.
- **Build number.** `CFBundleVersion` is the commit count (`git rev-list --count HEAD`), so it rises with every commit on `main`.
- **Commit.** The short SHA, in `ScribeGitSHA`.

The values in `project.yml` are placeholders.

### Testing process taps (do this early)

Start a Zoom call or play audio in Chrome, then run:

```bash
cd Packages/ScribeKit && swift run scribe-tapcheck --bundle com.google.Chrome --seconds 10
```

Leave out `--bundle` to tap all apps, or use `--bundle us.zoom.xos` for Zoom. The tool prints per-second levels and writes `tapcheck-system.m4a`. If every level reads as silence, the System Audio Recording permission was denied for your terminal.

</details>

## Local Cohere Transcribe

Select **Settings ▸ Transcription ▸ Provider ▸ Cohere Transcribe (on-device)**, then **Download Model**. It needs an Apple Silicon Mac. Scribe downloads the [MLX checkpoint](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-fp16) and reuses the cached weights. Allow several GB of disk space and memory for this 2B-parameter model. Wait for **Ready** before recording.

Transcription runs in the app through [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift), without Python, a server, or an API key. After the download, audio transcription works offline. Q&A and summaries still use the selected AI provider. The default language is English. Transcript updates use short audio windows, with final segments on pauses or after 25 seconds of continuous speech. Custom vocabulary is not passed to the model; Scribe's transcript corrections still apply.

The Model field accepts compatible Cohere Transcribe MLX checkpoint repository IDs, not the original PyTorch weights. Building this provider needs Swift 6.3 or later and Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).

### Manage local models

Use the **Model** dropdown for the known Cohere and Whisper checkpoints. This list works offline. Choose **Custom…** only when you need to enter another checkpoint ID; existing custom selections are kept.

Settings shows the selected Cohere or Whisper model's download progress, loading state, errors, and cached file size. Percentages use the provider's download work units, which can be files rather than bytes. Use **Retry** after a failure or **Delete Model…** to remove its cached files and unload it. Deletion is disabled while a model loads or a meeting captures audio. Meeting data is not deleted.

Missing models wait for **Download Model** (or the download prompt when starting a recording). Cached models load when selected or when Scribe starts. A deleted model does not download again on launch. Cohere uses the shared Hugging Face cache; its delete confirmation notes that other apps can use the same files. Whisper deletion affects only the selected variant, not other cached variants.

## Todos

Choose **Todos** in the sidebar to manage tasks without starting a meeting. Add a title for quick capture, click a task to edit its owner, notes, and due date, and use the circle to complete or reopen it. **Open**, **Today**, and **Completed** provide separate views. Today includes overdue tasks. Search matches task text, owners, and meeting titles.

Meeting summary action items are added automatically, including actions from summaries saved before this version. Use the plus button in a live or finished meeting to add a linked todo yourself. Source links open the original meeting. Deleting a meeting keeps its todos, with the old meeting title but no live link.

Imported tasks become user-owned. Summary regeneration does not overwrite edits or completion, and deleted imports do not return. Matching uses the meeting, task wording, and owner, ignoring case and repeated whitespace; differently worded actions can be new tasks. Manually added meeting tasks use the same matching rule. Completion does not rewrite the historical summary.

Exact `YYYY-MM-DD` dates become due dates. Other wording, such as “Friday” or “next week”, stays as an unconfirmed suggestion until you choose a date. Unconfirmed suggestions are not treated as overdue. Todos are stored locally in SQLite. No extra AI requests or audio storage are needed.

## Ask across saved meetings

Choose **Ask your meetings** in the sidebar to ask about decisions, owners, or discussions across all saved transcripts, notes, and summaries. This searches the whole library, independent of the selected folder or tag. Answers stream from the selected AI provider. Expand **Source quotes** to inspect the saved excerpts; click a citation or meeting title to open its meeting.

Search uses keyword matching, with bounded excerpts from several meetings. It does not search audio or the web. Only matching excerpts and conversation context are sent to the configured AI provider. If nothing matches, Scribe returns a local no-results message without an AI request. Corrections and meeting deletions are reflected on the next question. Conversations stay in memory until cleared or Scribe quits.

## Live transcription recovery

Microphone and system audio have separate status labels in the meeting view. If a transcriber throws an error or ends unexpectedly, Scribe restarts that track without ending the meeting or restarting the other track. It also restarts a transcriber after 60 seconds without new results when speech-like audio has been received. Quiet audio alone does not trigger this check.

Scribe makes up to three automatic retries with increasing delays. If they fail, use **Retry** beside the affected track. Existing final text is kept. Partial text is saved as the best available text before a restart. Retries use only the most recent 30 seconds of unconfirmed audio in memory, with no audio files. Older audio outside that buffer cannot be recovered; Scribe warns if it may be missing. Stopping capture cancels pending retries.

## Audio storage

New meetings do not save audio or timing files. There is no playback or retranscription action. Audio recordings from older versions remain untouched; deleting an old meeting still removes its recordings after confirmation. Diagnostic tools such as `scribe-tapcheck` can still write audio when explicitly run.

## Adding a provider

1. Write an adapter conforming to `TranscriptionProvider`, `LLMProvider` or `WebSearchTool` in its own folder under `Transcription/`, `Intelligence/Providers/` or `Intelligence/WebSearch/`.
2. Add one `register` line in `App/Providers.swift`.

## Release

1. Set `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig`.
2. Store your notary credentials once:

   ```bash
   xcrun notarytool store-credentials scribe-notary --apple-id you@example.com --team-id TEAMID
   ```

3. Tag the release. Pick `patch`, `minor` or `major` by semver. The script tags `HEAD` with the next version and prints the push command:

   ```bash
   scripts/bump.sh minor
   ```

4. Build, notarize and staple. This refuses to run unless `HEAD` is a version tag:

   ```bash
   scripts/release.sh
   ```

5. Push the commit and its tag. `bump.sh` makes annotated tags, so `--follow-tags` pushes them with `main`:

   ```bash
   git push origin main --follow-tags
   ```

The app is unsandboxed, uses the hardened runtime with `com.apple.security.device.audio-input`, and is signed with Developer ID.

### Installing a local build without Developer ID

Until the Developer ID certificate exists, `scripts/release.sh` can't sign. To put a Release build in `/Applications` on your own Mac, build it unsigned and sign it with your Apple Development certificate. That's the same certificate Debug builds use, so macOS keeps Scribe's permissions and Keychain access. From the repo root:

1. Build Release without signing:

   ```bash
   xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/ReleaseCheck build CODE_SIGNING_ALLOWED=NO
   ```

2. Copy it into a new folder named after the commit:

   ```bash
   ditto build/ReleaseCheck/Build/Products/Release/Scribe.app build/release-$(git rev-parse --short HEAD)/Scribe.app
   ```

3. Sign it with your Apple Development certificate (`security find-identity -v -p codesigning` lists it):

   ```bash
   codesign --force --deep --options runtime --timestamp=none --entitlements App/Scribe.entitlements --sign "Apple Development" build/release-$(git rev-parse --short HEAD)/Scribe.app
   ```

4. Quit the running Scribe:

   ```bash
   osascript -e 'quit app "Scribe"'
   ```

5. Delete the old copy:

   ```bash
   rm -rf /Applications/Scribe.app
   ```

6. Copy in the new one:

   ```bash
   ditto build/release-$(git rev-parse --short HEAD)/Scribe.app /Applications/Scribe.app
   ```

7. Open it:

   ```bash
   open /Applications/Scribe.app
   ```

This build isn't notarized, so it's only for your own Mac. Gatekeeper blocks it anywhere else.

## Permissions

- **Microphone.** `NSMicrophoneUsageDescription`. Scribe asks when the first recording starts.
- **System audio recording.** `NSAudioCaptureUsageDescription`. macOS asks the first time Scribe creates a process tap.
- **Accessibility.** Only Teams and Meet detection needs it, to read window titles. Enable it from the menu bar or in Settings.
- **Notifications.** Scribe uses them for the "Record this meeting?" prompt. Set Scribe to the *Alerts* style if you want the Record button to stay visible.

## Known gaps / next

- Speakerphone echo suppression filters transcript lines. Room acoustics and low-volume local speech can still affect its decisions.
- The Meet probe only sees each browser window's active tab. A browser-extension `MeetingDetector` is planned.
- Anthropic `pause_turn`, used for long server-tool turns, isn't continued automatically yet.
- Long meetings send the most recent ~120k characters of transcript. `TranscriptContextProvider` is the seam for adding chunking or retrieval.
- Transcription, summaries, and extracted action items can contain errors. Check important details against the transcript.
