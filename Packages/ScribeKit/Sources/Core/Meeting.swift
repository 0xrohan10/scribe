import Foundation

public enum MeetingApp: Sendable, Hashable, Codable {
    case zoom
    case teams
    case meet
    case other(String)

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        case .other(let name): name
        }
    }
}

public enum MeetingEvent: Sendable, Hashable {
    case started(app: MeetingApp, pid: pid_t)
    case ended
}

public protocol MeetingDetector: Sendable {
    /// Each access returns a new subscription.
    var events: AsyncStream<MeetingEvent> { get }
}

public struct Meeting: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var title: String
    public var app: MeetingApp?
    public var startedAt: Date
    public var endedAt: Date?
    public var templateID: String
    public var micAudioPath: String?
    public var systemAudioPath: String?

    public init(
        id: UUID = UUID(), title: String, app: MeetingApp? = nil, startedAt: Date = .now, endedAt: Date? = nil,
        templateID: String = SummaryTemplate.general.id, micAudioPath: String? = nil, systemAudioPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.app = app
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.templateID = templateID
        self.micAudioPath = micAudioPath
        self.systemAudioPath = systemAudioPath
    }
}

public struct Note: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let meetingID: UUID
    public var text: String
    /// Seconds on the session clock when the note was started.
    public var timestamp: TimeInterval
    public var flagged: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), meetingID: UUID, text: String, timestamp: TimeInterval, flagged: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.timestamp = timestamp
        self.flagged = flagged
        self.createdAt = createdAt
    }
}

public struct ActionItem: Sendable, Hashable, Codable {
    public var task: String
    public var owner: String?
    public var due: String?

    public init(task: String, owner: String? = nil, due: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
    }
}

public struct MeetingSummary: Sendable, Hashable, Codable {
    public var meetingID: UUID
    public var templateID: String
    public var overview: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    /// Items the user flagged in their notes, as the model restated them.
    public var flagged: [String]
    public var createdAt: Date

    public init(
        meetingID: UUID, templateID: String, overview: String, decisions: [String] = [], actionItems: [ActionItem] = [],
        openQuestions: [String] = [], flagged: [String] = [], createdAt: Date = .now
    ) {
        self.meetingID = meetingID
        self.templateID = templateID
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.flagged = flagged
        self.createdAt = createdAt
    }
}

public struct SummaryTemplate: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var name: String
    /// Extra guidance appended to the summary prompt.
    public var instructions: String

    public init(id: String, name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
    }

    public static let general = SummaryTemplate(id: "general", name: "General", instructions: "")
}

public protocol MeetingSummarizer: Sendable {
    func summarize(meeting: Meeting, transcript: Transcript, notes: [Note]) async throws -> MeetingSummary
}
