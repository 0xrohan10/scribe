# Scribe guide

[Back to README](../README.md)

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
  Notes/                  NotesController, NoteDraft, NoteAnchoring
  Session/                MeetingSession manages meeting state, per-source transcription, and persistence
  Persistence/            GRDB database + repositories, DiskAudioFileStore
  Settings/               AppSettings (UserDefaults), KeychainSecretStore
  GoogleCalendar/         read-only Google Calendar client, OAuth loopback sign-in, PKCE
  Fixtures/               fake audio and an echo LLM for the `scribe` CLI and the app's --ui-testing mode
  Tools/TapCheck/         `scribe-tapcheck` CLI for testing process taps
  Tools/ScribeCLI/        `scribe` dev-debugging CLI: fake meetings, database dumps, search-gate scores, UI driving
project.yml               XcodeGen spec for Scribe.xcodeproj
```

Each `AudioSource` streams 16 kHz mono `AudioChunk`s into its own `transcribe` call without a recording file. The microphone track is "Me" and system audio is "Them", so no diarization is needed. `MeetingSession` merges the segments, broadcasts `SessionEvent`s to the UI, and saves final segments.

When both tracks are available, signal-based echo detection filters microphone segments that match delayed speaker audio. The detector retains local speech that overlaps the other side. It is adapted from [Hex](https://github.com/anomalyco/hex). See [third-party notices](../THIRD_PARTY_NOTICES.md).

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

Run `swift test --sanitize=thread` after changing capture or session code. `CaptureSinkTests` can detect recording-file races only with Thread Sanitizer enabled.

Run app-model tests with `xcodebuild test -project Scribe.xcodeproj -scheme Scribe -destination 'platform=macOS'`. These tests use isolated preferences and an in-memory secret store.

Debug builds can render the main screens with demo data, without permissions or API keys. Run the built app binary with `--screenshots <dir>`, for example `build/DerivedData/Build/Products/Debug/Scribe.app/Contents/MacOS/Scribe --screenshots build/screenshots`.

The `scribe` CLI has three debugging commands:

- `demo` runs the session, notes, Q&A, and summary code with fake audio, transcription, and AI responses.
- `db` dumps a database.
- `gate` scores questions with the Jev search gate through its API.

See `swift run scribe help <subcommand>`.

```bash
cd Packages/ScribeKit && swift run scribe demo --seconds 12 --note "5:! billing is the main risk" --ask "7:what did they just say?"
```

`scribe ui` controls the app through the Accessibility API. It launches the Debug build with `--ui-testing` to use fake audio, transcription, and AI responses. Test data goes in a temporary folder.

`scribe ui demo` tests capture, notes, Q&A, summaries, meeting organization, and todos. It checks the UI and saved database, then exits non-zero on the first failure. Your terminal needs Accessibility access. Build the Debug app first.

```bash
cd Packages/ScribeKit && swift run scribe ui demo
```

Use `launch`, `menu`, `press`, `type`, `wait`, `read`, `tree`, `screenshot`, and `quit` to test other flows. Queries match accessibility identifiers such as `notes.add`, titles, or labels. Run `scribe ui tree` to list them.

After building Debug, run `swift scripts/check-calendar-ui.swift` from the repo root to check Google Calendar setup, configuration save, and Upcoming navigation. This starts a separate app instance with fake providers and temporary meeting data. It does not open Google sign-in or use real credentials. The terminal needs Accessibility access.

One drawing generates the app icon at `App/AppIcon.icon` and the menu bar mark, `ScribeMark` in `App/Assets.xcassets`. After changing the drawing, run `swift scripts/make-icons.swift`.

Debug builds use your Apple Development certificate, so macOS keeps their permissions and Keychain access across rebuilds. Create a certificate in Xcode ▸ Settings ▸ Accounts.

Settings ▸ About shows the version, build number, and source commit. On each build, `scripts/stamp-version.sh` reads these values from git and writes them to the app's Info.plist.

- The version comes from the latest `vX.Y.Z` tag. Later commits use the next patch's prerelease version. Three commits after `v0.2.0` produce `0.2.1-dev.3`. `ScribeVersion` stores the full version. `CFBundleShortVersionString` stores the tag's numeric `X.Y.Z`, as macOS requires.
- `CFBundleVersion` stores the commit count from `git rev-list --count HEAD`. It increases with each commit on `main`.
- `ScribeGitSHA` stores the short commit SHA.

The values in `project.yml` are placeholders.

### Test process taps

Start a Zoom call or play audio in Chrome, then run:

```bash
cd Packages/ScribeKit && swift run scribe-tapcheck --bundle com.google.Chrome --seconds 10
```

Leave out `--bundle` to tap all apps, or use `--bundle us.zoom.xos` for Zoom. The tool prints per-second levels and writes `tapcheck-system.m4a`. If every level reads as silence, the System Audio Recording permission was denied for your terminal.

## Local Cohere Transcribe

Select **Settings ▸ Transcription ▸ Provider ▸ Cohere Transcribe (on-device)**, then **Download Model**. It needs an Apple Silicon Mac. Scribe downloads the [MLX checkpoint](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-fp16) and reuses the cached weights. Allow several GB of disk space and memory for this 2B-parameter model. Wait for **Ready** before recording.

Transcription runs in the app through [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift), without Python, a server, or an API key. After the download, audio transcription works offline. Q&A and summaries still use the selected AI provider. The default language is English. Transcript updates use short audio windows, with final segments on pauses or after 25 seconds of continuous speech. Custom vocabulary is not passed to the model; Scribe's transcript corrections still apply.

The Model field accepts compatible Cohere Transcribe MLX checkpoint repository IDs, not the original PyTorch weights. Building this provider needs Swift 6.3 or later and Xcode's Metal toolchain. Install the toolchain with `xcodebuild -downloadComponent MetalToolchain`.

### Manage local models

Use the **Model** dropdown for the known Cohere and Whisper checkpoints. This list works offline. Choose **Custom…** only when you need to enter another checkpoint ID; existing custom selections are kept.

Settings shows the selected Cohere or Whisper model's download progress, loading state, errors, and cached file size. Percentages use the provider's download work units, which can be files rather than bytes. Use **Retry** after a failure or **Delete Model…** to remove its cached files and unload it. Deletion is disabled while a model loads or a meeting captures audio. Meeting data is not deleted.

To download a missing model, choose **Download Model** or accept the prompt when starting capture. Cached models load when selected or when Scribe starts. A deleted model does not download again on launch. Cohere uses the shared Hugging Face cache. Its delete confirmation warns that other apps may use the same files. Deleting a Whisper model removes only the selected variant.

## Google Calendar

Choose **Settings ▸ Google Calendar** to connect Google accounts. Select the calendars to show for each account. **Upcoming** shows timed events for the next seven days, including meetings in progress. All-day events, cancelled events, and events you declined are not shown. Times use your Mac's time zone. The page refreshes when opened and once per minute while open. Use **Refresh** to check again.

Choose **Start recording** beside an event to create a meeting with its title. This uses the normal recording permissions and transcription settings. It does not join a call, open a meeting link, or start recording automatically. Scribe does not change Google Calendar events.

### Set up Google sign-in

This source build needs your own Google OAuth configuration:

1. In [Google Cloud Console](https://console.cloud.google.com/), create or select a project and enable **Google Calendar API**.
2. Configure the OAuth consent screen. For an external app in Testing, add the Google accounts you will connect as test users. Add the read-only Calendar list and event scopes (`https://www.googleapis.com/auth/calendar.calendarlist.readonly` and `https://www.googleapis.com/auth/calendar.events.readonly`), plus `openid` and `email`.
3. Create an OAuth client with application type **Desktop app**. Do not use a Web application client.
4. In Scribe's calendar settings, enter the client ID and the client secret if Google supplied one. Choose **Save configuration**, then **Add Google account**.
5. Complete sign-in in your browser. Scribe receives the result through a temporary local loopback listener. The primary calendar is selected by default. You can select other calendars or add another account.

Use **Add Google account** to sign in again if access expires. External Google apps in Testing can have refresh tokens that expire after seven days. A distributed app needs its own OAuth consent and verification setup. Disconnect all accounts before changing the OAuth client configuration.

Scribe stores refresh tokens and the optional client secret in Keychain. It stores account emails, calendar names, and selections in local preferences. Upcoming event data stays in memory; starting a recording saves its title in the local meeting database. **Disconnect** removes that account's local credentials and events. It does not delete saved meetings or revoke the Google grant. To revoke access, remove Scribe in your Google account's third-party connections settings.

## Todos

Choose **Todos** in the sidebar to manage tasks without starting a meeting. Enter a title to add a task. Click a task to edit its owner, notes, and due date. Use the circle to complete or reopen it. Filter with **Open**, **Today**, or **Completed**. Today includes overdue tasks. Search matches task text, owners, and meeting titles.

Scribe imports meeting summary action items, including actions from summaries saved before this version. Use the plus button in a live or finished meeting to add a linked todo yourself. Source links open the original meeting. Deleting a meeting keeps its todos with the old meeting title but no live link.

Regenerating a summary preserves task edits and completion. It does not restore deleted imports. Matching uses the meeting, task wording, and owner, ignoring case and repeated whitespace. Different wording can create a new task. Manually added meeting tasks use the same matching rule. Completing a task does not change the saved summary.

Exact `YYYY-MM-DD` dates become due dates. Other wording, such as "Friday" or "next week", stays as an unconfirmed suggestion until you choose a date. Unconfirmed suggestions do not count as overdue. Scribe stores todos locally in SQLite without extra AI requests or audio storage.

## Ask across saved meetings

Choose **Ask your meetings** in the sidebar to ask about decisions, owners, or discussions across all saved transcripts, notes, and summaries. This searches the whole library, independent of the selected folder or tag. Answers stream from the selected AI provider. Expand **Source quotes** to inspect the saved excerpts; click a citation or meeting title to open its meeting.

Search uses keyword matching and limits the excerpts it selects from each meeting. It does not search audio or the web. Scribe sends only matching excerpts and conversation context to the configured AI provider. If nothing matches, Scribe returns a no-results message without an AI request. The next question uses any transcript corrections or meeting deletions. Conversations stay in memory until you clear them or quit Scribe.

## Live transcription recovery

Microphone and system audio have separate status labels in the meeting view. If a transcriber throws an error or ends unexpectedly, Scribe restarts that track. The meeting and the other track continue. Scribe also restarts a transcriber if it receives speech-like audio but produces no new results for 60 seconds. Quiet audio alone does not trigger this check.

Scribe retries up to three times with increasing delays. If retries fail, use **Retry** beside the affected track. Scribe keeps final text and saves partial text before a restart. Retries use only the most recent 30 seconds of unconfirmed audio in memory, with no audio files. Scribe cannot recover older audio outside that buffer and warns if text may be missing. Stopping capture cancels pending retries.

## Meeting titles

When a recording ends, Scribe uses the selected AI provider to create a short title from the transcript. This also runs when automatic summaries are off. If no AI provider is available or the transcript is empty, the current title stays unchanged. A title-generation error does not prevent the summary from completing.

Edit the title and choose **Save**, or press Return, to save your own title. This works during recording and when reviewing a saved meeting. Changes are not saved while you type. A title you save during recording takes priority over the generated title, including while an AI request is in progress.

## Audio storage

New meetings do not save audio or timing files. There is no playback or retranscription action. Audio recordings from older versions remain untouched; deleting an old meeting still removes its recordings after confirmation. Diagnostic tools such as `scribe-tapcheck` can still write audio when explicitly run.

## Adding a provider

1. Write an adapter that conforms to `TranscriptionProvider`, `LLMProvider`, or `WebSearchTool`. Put it in its own folder under `Transcription/`, `Intelligence/Providers/`, or `Intelligence/WebSearch/`.
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

3. Sign it with your Apple Development certificate. Run `security find-identity -v -p codesigning` to list certificates:

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
- Long meetings send about the most recent 120,000 characters of transcript. Extend `TranscriptContextProvider` to add chunking or retrieval.
- Transcription, summaries, and extracted action items can contain errors. Check important details against the transcript.

## License

Scribe is licensed under the [MIT License](../LICENSE). Third-party code retains its respective licenses; see [third-party notices](../THIRD_PARTY_NOTICES.md).
