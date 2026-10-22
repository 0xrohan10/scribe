import Core
import Foundation
import GRDB

private enum MeetingSearchTerms {
    static func extract(from query: String) -> [String] {
        let ignored: Set<String> = [
            "a", "an", "and", "are", "as", "at", "about", "across", "all", "be", "been", "but", "by", "can", "could",
            "did", "do", "does", "for", "from", "give", "had", "has", "have", "how", "i", "in", "is", "it", "its",
            "me", "meeting", "meetings", "my", "of", "on", "or", "our", "please", "said", "saved", "show", "some",
            "tell", "that", "the", "their", "them", "there", "these", "they", "this", "those", "to", "us", "was",
            "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your",
        ]
        var seen = Set<String>()
        return query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { word in
            var term = String(word)
            if term.count > 4, term.hasSuffix("s"), !term.hasSuffix("ss"), !term.hasSuffix("us"), !term.hasSuffix("is") {
                term.removeLast()
            }
            guard term.count > 1, !ignored.contains(term), seen.insert(term).inserted else { return nil }
            return term
        }.prefix(16).map { $0 }
    }
}

struct GRDBMeetingSearchRepository: MeetingSearchRepository {
    let writer: any DatabaseWriter

    func search(_ query: String, limit: Int) async throws -> [MeetingEvidence] {
        let terms = MeetingSearchTerms.extract(from: query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let limit = min(limit, 50)
        return try await writer.read { db in
            let values: [String: (any DatabaseValueConvertible)?] = Dictionary(uniqueKeysWithValues: terms.enumerated().map { ("term\($0.offset)", "%\($0.element)%") })
            let arguments = StatementArguments(values)
            func rows(table: String, text: String, extra: String, condition: String = "1") throws -> [Row] {
                let matches = terms.indices.map { "(lower(\(text)) LIKE :term\($0) OR lower(m.title) LIKE :term\($0))" }.joined(separator: " OR ")
                let score = terms.indices.map { "(CASE WHEN lower(\(text)) LIKE :term\($0) THEN 3 WHEN lower(m.title) LIKE :term\($0) THEN 1 ELSE 0 END)" }.joined(separator: " + ")
                return try Row.fetchAll(db, sql: """
                    SELECT * FROM (
                        SELECT m.*, \(extra), (\(score)) AS evidenceScore,
                            row_number() OVER (PARTITION BY m.id ORDER BY (\(score)) DESC, x.rowid) AS sourceRank
                        FROM \(table) x JOIN meeting m ON m.id = x.meetingID
                        WHERE \(condition) AND (\(matches))
                    ) WHERE sourceRank <= 4
                    ORDER BY evidenceScore DESC, startedAt DESC LIMIT \(limit * 8)
                    """, arguments: arguments)
            }
            var candidates: [MeetingEvidence] = []
            for row in try rows(table: "segment", text: "x.text", extra: "x.id AS evidenceID, x.text, x.start AS evidenceTime", condition: "x.isFinal = 1") {
                let id: UUID = row["evidenceID"]
                candidates.append(MeetingEvidence(id: "segment-\(id)", meeting: try MeetingRecord(row: row).model,
                                                  kind: .transcript, text: row["text"], timestamp: row["evidenceTime"]))
            }
            for row in try rows(table: "note", text: "x.text", extra: "x.id AS evidenceID, x.text, x.timestamp AS evidenceTime") {
                let id: UUID = row["evidenceID"]
                candidates.append(MeetingEvidence(id: "note-\(id)", meeting: try MeetingRecord(row: row).model,
                                                  kind: .note, text: row["text"], timestamp: row["evidenceTime"]))
            }
            for row in try rows(table: "summary", text: "x.payload", extra: "x.meetingID, x.payload, x.createdAt") {
                let meeting = try MeetingRecord(row: row).model
                let summary = try SummaryRecord(row: row).payload
                let sections: [(MeetingEvidence.Kind, [String])] = [
                    (.overview, [summary.overview]), (.decision, summary.decisions),
                    (.openQuestion, summary.openQuestions), (.flagged, summary.flagged),
                ]
                for (kind, items) in sections {
                    for (index, text) in items.enumerated() where !text.isEmpty {
                        candidates.append(MeetingEvidence(id: "summary-\(meeting.id)-\(kind.rawValue)-\(index)",
                                                          meeting: meeting, kind: kind, text: text))
                    }
                }
                for (index, item) in summary.actionItems.enumerated() where !item.task.isEmpty {
                    candidates.append(MeetingEvidence(id: "summary-\(meeting.id)-action-\(index)", meeting: meeting,
                                                      kind: .actionItem, text: item.task, owner: item.owner, due: item.due))
                }
            }
            func score(_ source: MeetingEvidence) -> Int {
                let text = [source.kind.rawValue, source.text, source.owner, source.due].compactMap { $0 }.joined(separator: " ").lowercased()
                let title = source.meeting.title.lowercased()
                return terms.reduce(0) { $0 + (text.contains($1) ? 3 : title.contains($1) ? 1 : 0) }
            }
            let ranked = candidates.filter { score($0) > 0 }.sorted {
                let left = score($0), right = score($1)
                if left != right { return left > right }
                if $0.meeting.startedAt != $1.meeting.startedAt { return $0.meeting.startedAt > $1.meeting.startedAt }
                return $0.id < $1.id
            }
            var perMeeting: [UUID: Int] = [:]
            var result: [MeetingEvidence] = []
            for var source in ranked {
                guard perMeeting[source.meeting.id, default: 0] < 4 else { continue }
                source.text = Self.excerpt(source.text, terms: terms)
                result.append(source)
                perMeeting[source.meeting.id, default: 0] += 1
                if result.count == limit { break }
            }
            return result
        }
    }

    private static func excerpt(_ text: String, terms: [String]) -> String {
        guard text.count > 1200 else { return text }
        let match = terms.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min() ?? text.startIndex
        let start = text.index(match, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(1200))
    }
}
