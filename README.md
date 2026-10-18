# Scribe

A macOS meeting-notes app. It records your mic and the meeting's system audio on the device (no bot joins the call), transcribes live, answers questions mid-meeting, keeps timestamped notes, and summarizes when the meeting ends.

macOS 14.2+ (Core Audio process taps). On-device transcription with `SpeechAnalyzer` needs macOS 26.

## Layout

```
App/                      thin app target: composition root (AppModel), MenuBarExtra, windows, views
  Providers.swift         provider registry: one line per transcription/LLM adapter
Packages/ScribeKit/       one SwiftPM target per domain; domains import only Core
  Core/                   models, provider + repository protocols, SessionClock, Broadcaster
  Capture/                MicrophoneSource (AVAudioEngine), SystemAudioSource (process tap + aggregate device), m4a writing
  Detection/              mic-in-use listener, Zoom (CptHost) / Teams / Meet (AX window titles) probes, MicTriggeredMeetingDetector
  Transcription/          Fake, SpeechAnalyzer; WhisperKit / Deepgram / AssemblyAI / OpenAI Realtime are TODO stubs
  Intelligence/           Anthropic (streaming + server web search), OpenAI-compatible, QAEngine, LLMSummarizer, prompts
  Notes/                  NotesController, NoteDraft (anchors to when you *start* typing), NoteAnchoring
  Session/                MeetingSession: lifecycle state machine, per-source transcription, persistence fan-out
  Persistence/            GRDB database + repositories, DiskAudioFileStore
  Settings/               AppSettings (UserDefaults), KeychainSecretStore
  Tools/TapCheck/         `scribe-tapcheck` CLI for testing process taps
project.yml               XcodeGen spec for Scribe.xcodeproj
```

Data flow: each `AudioSource` streams 16 kHz mono `AudioChunk`s, and writes its own `mic.m4a` / `system.m4a`, into its own `transcribe` call. Mic is "Me" and system audio is "Them", so no diarization is needed. `MeetingSession` merges the segments, broadcasts `SessionEvent`s to the UI and saves final segments.

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

Debug builds are signed ad hoc. That means macOS may ask again for permissions and Keychain access after rebuilds.

### Testing process taps (do this early)

Start a Zoom call or play audio in Chrome, then run:

```bash
cd Packages/ScribeKit && swift run scribe-tapcheck --bundle com.google.Chrome --seconds 10
```

Leave out `--bundle` to tap all apps, or use `--bundle us.zoom.xos` for Zoom. The tool prints per-second levels and writes `tapcheck-system.m4a`. If every level reads as silence, the System Audio Recording permission was denied for your terminal.

## Adding a provider

1. Write an adapter conforming to `TranscriptionProvider` or `LLMProvider` in its own folder under `Transcription/` or `Intelligence/Providers/`.
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

## Permissions

- **Microphone:** `NSMicrophoneUsageDescription`. Requested when the first recording starts.
- **System audio recording:** `NSAudioCaptureUsageDescription`. Requested the first time a process tap is created.
- **Accessibility:** needed only for Teams and Meet detection, which reads window titles. Enable it from the menu bar or in Settings.
- **Notifications:** used for the "Record this meeting?" prompt. Set Scribe to the *Alerts* style if you want the Record button to stay visible.

## Known gaps / next

- Without headphones, the mic also picks up the other side, so the same speech can appear twice: once as "Me" and once as "Them". Possible fixes: voice processing (AEC) on the input node, or suppressing mic segments that match system audio.
- The Meet probe only sees each browser window's active tab. A browser-extension `MeetingDetector` is planned.
- Anthropic `pause_turn`, used for long server-tool turns, isn't continued automatically yet.
- Long meetings send the most recent ~120k characters of transcript. `TranscriptContextProvider` is the seam for adding chunking or retrieval.
- Recordings are 16 kHz mono AAC: speech quality, not archival quality.
