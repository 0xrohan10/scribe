import Core
import Foundation

public struct DiskAudioFileStore: AudioFileStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func recordingURL(meetingID: UUID, source: AudioChunk.Source) throws -> URL {
        let dir = root.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(source.rawValue).m4a")
    }

    public func deleteRecordings(meetingID: UUID) throws {
        let dir = root.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
