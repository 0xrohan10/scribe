import Foundation

/// A saved text excerpt with an application-owned meeting link, never a model-generated URL.
public struct MeetingEvidence: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case transcript = "Transcript"
        case note = "Note"
        case overview = "Summary"
        case decision = "Decision"
        case actionItem = "Action item"
        case openQuestion = "Open question"
        case flagged = "Flagged item"
    }

    public let id: String
    public let meeting: Meeting
    public let kind: Kind
    public var text: String
    public let timestamp: TimeInterval?
    public let owner: String?
    public let due: String?

    public init(id: String, meeting: Meeting, kind: Kind, text: String, timestamp: TimeInterval? = nil, owner: String? = nil, due: String? = nil) {
        self.id = id
        self.meeting = meeting
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.owner = owner
        self.due = due
    }
}

public protocol MeetingSearchRepository: Sendable {
    /// Searches saved text across the library. Results contain exact saved excerpts and current meeting metadata.
    func search(_ query: String, limit: Int) async throws -> [MeetingEvidence]
}
