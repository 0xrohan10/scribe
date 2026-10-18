import Capture
import Core
import Foundation

// Smoke test for process taps, since that's where capture is riskiest (Chrome/Zoom render audio in helper
// processes). Start a call or play audio, then:
//
//   swift run scribe-tapcheck                                  # all apps except this one
//   swift run scribe-tapcheck --bundle com.google.Chrome       # Chrome + helpers
//   swift run scribe-tapcheck --bundle us.zoom.xos --seconds 20
//
// Prints a level meter per second and writes ./tapcheck-system.m4a. All-zero levels usually mean the
// System Audio Recording permission was denied for your terminal (System Settings ▸ Privacy & Security).

var args = CommandLine.arguments.dropFirst()
var bundles: [String] = []
var seconds = 10.0
while let arg = args.popFirst() {
    switch arg {
    case "--bundle": bundles.append(args.popFirst() ?? "")
    case "--seconds": seconds = Double(args.popFirst() ?? "") ?? seconds
    default: print("unknown argument \(arg)"); exit(2)
    }
}

let scope: SystemAudioScope = bundles.isEmpty ? .allApps : .bundleIDs(bundles)
let output = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "tapcheck-system.m4a")
let source = SystemAudioSource(scope: scope)
let clock = SessionClock()

print("Tapping \(scope) for \(Int(seconds))s → \(output.path)")
let stream: AsyncStream<AudioChunk>
do {
    stream = try await source.start(clock: clock, recordingTo: output)
} catch {
    print("✗ \(error.localizedDescription)")
    exit(1)
}

let stopper = Task {
    try await Task.sleep(for: .seconds(seconds))
    await source.stop()
}

var second = 0
var sumSquares: Float = 0
var count = 0
var peakOverall: Float = 0
for await chunk in stream {
    for s in chunk.pcm {
        sumSquares += s * s
        peakOverall = max(peakOverall, abs(s))
    }
    count += chunk.pcm.count
    if Int(chunk.timestamp) > second {
        let rms = count > 0 ? (sumSquares / Float(count)).squareRoot() : 0
        let db = 20 * log10(max(rms, 1e-6))
        print(String(format: "%3ds  %6.1f dBFS  %@", second, db, String(repeating: "█", count: max(0, Int((db + 60) / 2)))))
        second = Int(chunk.timestamp)
        sumSquares = 0
        count = 0
    }
}
_ = try? await stopper.value
print(peakOverall > 0.0001 ? "✓ Captured audio (peak \(peakOverall))." : "✗ Only silence. Check the System Audio Recording permission.")
