# Scribe

A macOS meeting-notes app. It records your mic and the meeting's system audio on the device (no bot joins the call), transcribes live, answers questions mid-meeting, keeps timestamped notes, and summarizes when the meeting ends.

macOS 14.2+ (Core Audio process taps). On-device transcription with `SpeechAnalyzer` needs macOS 26.

## Layout

```
App/                      thin app target: composition root (AppModel), MenuBarExtra, the main window, views
  Providers.swift         provider registry: one line per transcription/LLM adapter
Packages/ScribeKit/       one SwiftPM target per domain; domains import only Core
  Core/                   models, provider + repository protocols, SessionClock, Broadcaster
  Capture/                MicrophoneSource (AVAudioEngine), SystemAudioSource (process tap + aggregate device), m4a writing
  Detection/              mic-in-use listener, Zoom (CptHost) / Teams / Meet (AX window titles) probes, MicTriggeredMeetingDetector
  Transcription/          Fake, SpeechAnalyzer, WhisperKit; Deepgram / AssemblyAI / OpenAI Realtime are TODO stubs
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

Data flow: each `AudioSource` writes its own `mic.m4a` or `system.m4a` and streams 16 kHz mono `AudioChunk`s into its own `transcribe` call. Mic is "Me" and system audio is "Them", so no diarization is needed. `MeetingSession` merges the segments, broadcasts `SessionEvent`s to the UI and saves final segments.

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

### Testing process taps (do this early)

Start a Zoom call or play audio in Chrome, then run:

```bash
cd Packages/ScribeKit && swift run scribe-tapcheck --bundle com.google.Chrome --seconds 10
```

Leave out `--bundle` to tap all apps, or use `--bundle us.zoom.xos` for Zoom. The tool prints per-second levels and writes `tapcheck-system.m4a`. If every level reads as silence, the System Audio Recording permission was denied for your terminal.

## Adding a provider

1. Write an adapter conforming to `TranscriptionProvider`, `LLMProvider` or `WebSearchTool` in its own folder under `Transcription/`, `Intelligence/Providers/` or `Intelligence/WebSearch/`.
2. Add one `register` line in `App/Providers.swift`.

## Release

1. Set `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig`.
2. Store your notary credentials once:

   ```bash
   xcrun notarytool store-credentials scribe-notary --apple-id you@example.com --team-id TEAMID
   ```

3. Build, notarize and staple:

   ```bash
   scripts/release.sh
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

- Without headphones, the mic also picks up the other side, so the same speech can appear twice: once as "Me" and once as "Them". Possible fixes: voice processing (AEC) on the input node, or suppressing mic segments that match system audio.
- The Meet probe only sees each browser window's active tab. A browser-extension `MeetingDetector` is planned.
- Anthropic `pause_turn`, used for long server-tool turns, isn't continued automatically yet.
- Long meetings send the most recent ~120k characters of transcript. `TranscriptContextProvider` is the seam for adding chunking or retrieval.
- Recordings are 16 kHz mono AAC: speech quality, not archival quality.
