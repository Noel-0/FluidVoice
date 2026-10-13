@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class FluidServeTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FluidServeTests-\(UUID().uuidString)", isDirectory: true)
        self.root = base.appendingPathComponent("Meetings", isDirectory: true)
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root.deletingLastPathComponent())
    }

    // MARK: - Reader

    func testReaderPrintsTheSameTranscriptAsTheApp() throws {
        let session = self.session(title: "Weekly sync")
        try self.save(session)

        let entries = FluidServeMeetings.entries(root: self.root)
        XCTAssertEqual(entries.count, 1)
        let meeting = try XCTUnwrap(entries.first).meeting
        XCTAssertEqual(meeting.id, session.id)
        XCTAssertEqual(meeting.title, "Weekly sync")
        XCTAssertEqual(meeting.activeSpeakers.map(\.displayName), session.activeSpeakers.map(\.displayName))
        XCTAssertEqual(FluidServeMeetings.transcript(for: meeting), MeetingTranscriptExporter.text(for: session))
        XCTAssertFalse(FluidServeMeetings.transcript(for: meeting).contains("echo of the far side"))
        XCTAssertTrue(FluidServeMeetings.transcript(for: meeting).contains("[00:20] Priya: merged speaker keeps the name"))
        XCTAssertTrue(FluidServeMeetings.transcript(for: meeting).contains("[00:30] Unknown speaker: two people at once"))
    }

    func testMeetingsStillRecordingEmptyOrUnreadableAreNotServed() throws {
        var recording = self.session(title: "Still recording")
        recording.state = .recording
        recording.endedAt = nil
        try self.save(recording)
        var empty = self.session(title: "No words")
        empty.transcriptSegments = []
        try self.save(empty)
        let broken = self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("session.json"))
        try self.save(self.session(title: "Finished"))

        XCTAssertEqual(FluidServeMeetings.entries(root: self.root).map(\.meeting.title), ["Finished"])
    }

    func testNewestMeetingIsFirstAndSinceLeavesOlderOnesOut() throws {
        try self.save(self.session(title: "Old", startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        try self.save(self.session(title: "New", startedAt: Date(timeIntervalSince1970: 1_700_500_000)))

        XCTAssertEqual(FluidServeMeetings.entries(root: self.root).map(\.meeting.title), ["New", "Old"])
        let since = Date(timeIntervalSince1970: 1_700_400_000)
        XCTAssertEqual(FluidServeMeetings.entries(root: self.root, since: since).map(\.meeting.title), ["New"])
    }

    func testArgumentParsing() {
        XCTAssertEqual(FluidServeMeetings.seconds(fromClock: "90"), 90)
        XCTAssertEqual(FluidServeMeetings.seconds(fromClock: "12:30"), 750)
        XCTAssertEqual(FluidServeMeetings.seconds(fromClock: "1:02:03"), 3723)
        XCTAssertNil(FluidServeMeetings.seconds(fromClock: "soon"))
        XCTAssertNil(FluidServeMeetings.seconds(fromClock: "1:2:3:4"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(FluidServeMeetings.sinceDate(from: "7d", now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(FluidServeMeetings.sinceDate(from: "24h", now: now), now.addingTimeInterval(-86_400))
        XCTAssertNotNil(FluidServeMeetings.sinceDate(from: "2026-10-01", now: now))
        XCTAssertNil(FluidServeMeetings.sinceDate(from: "last week", now: now))
    }

    // MARK: - Command

    func testCommandStaysClosedUntilAccessIsOn() throws {
        try self.save(self.session(title: "Private planning"))

        for arguments in [["meet", "list"], ["meet", "show", "latest"], ["meet", "search", "merged"], ["meet", "summary", "latest"]] {
            let result = FluidServeCommand.run(arguments: arguments, root: self.root, accessEnabled: false)
            XCTAssertEqual(result.exitCode, 2, "\(arguments)")
            XCTAssertFalse(result.output.contains("Private planning"), "\(arguments)")
            XCTAssertFalse(result.output.contains("merged speaker"), "\(arguments)")
        }
        let status = FluidServeCommand.run(arguments: ["status"], root: self.root, accessEnabled: false)
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertTrue(status.output.contains("Meeting access: off"))
        XCTAssertFalse(status.output.contains("Meetings available"))
    }

    func testAccessSwitchIsOffUntilTheAppSetsIt() throws {
        let suite = "FluidServeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FluidServeMeetings.isAccessEnabled(bundleIdentifier: suite))
        defaults.set(true, forKey: FluidServeMeetings.accessDefaultsKey)
        XCTAssertTrue(FluidServeMeetings.isAccessEnabled(bundleIdentifier: suite))
    }

    func testCommandListsShowsSearchesAndReadsSavedSummaries() throws {
        let session = self.session(title: "Weekly sync")
        try self.save(session)
        let saved = MeetingSummaryController.SavedSummary(
            transcriptHash: "hash",
            modelID: "model",
            text: "## Overview\nShort and clear.",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            modelName: "Qwen3.5 9B"
        )
        try JSONEncoder().encode(saved).write(to: self.directory(for: session).appendingPathComponent("manual-summary-executive.json"))
        let prefix = String(session.id.uuidString.prefix(8))

        let list = self.run("meet", "list")
        XCTAssertEqual(list.exitCode, 0)
        XCTAssertTrue(list.output.contains(prefix))
        XCTAssertTrue(list.output.contains("Weekly sync"))
        XCTAssertTrue(list.output.hasSuffix("executive"))

        let show = self.run("meet", "show", prefix)
        XCTAssertEqual(show.exitCode, 0)
        XCTAssertTrue(show.output.contains("Title: Weekly sync"))
        XCTAssertTrue(show.output.hasSuffix(MeetingTranscriptExporter.text(for: session)))
        XCTAssertEqual(self.run("meet", "show").output, show.output, "No id means the newest meeting")

        let range = self.run("meet", "show", "latest", "--from", "0:15", "--to", "0:25")
        XCTAssertTrue(range.output.contains("merged speaker keeps the name"))
        XCTAssertFalse(range.output.contains("first words"))
        XCTAssertFalse(range.output.contains("two people at once"))

        let search = self.run("meet", "search", "MERGED")
        XCTAssertEqual(search.exitCode, 0)
        XCTAssertTrue(search.output.contains("[00:20] Priya: merged speaker keeps the name"))
        XCTAssertTrue(self.run("meet", "search", "zebra").output.contains("No transcript mentions"))

        let summary = self.run("meet", "summary", "latest")
        XCTAssertEqual(summary.exitCode, 0)
        XCTAssertTrue(summary.output.contains("Style: executive"))
        XCTAssertTrue(summary.output.contains("Written by: Qwen3.5 9B"))
        XCTAssertTrue(summary.output.hasSuffix("## Overview\nShort and clear."))
        XCTAssertEqual(self.run("meet", "summary", "latest", "--style", "actions").exitCode, 1)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(self.run("meet", "show", "latest", "--json").output.utf8)) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Weekly sync")
        XCTAssertEqual((json["turns"] as? [[String: Any]])?.count, 3)
    }

    func testCommandExplainsBadInput() throws {
        try self.save(self.session(title: "Weekly sync"))
        XCTAssertEqual(self.run("meet", "show", "ffffffff").exitCode, 1)
        XCTAssertTrue(self.run("meet", "show", "ffffffff").output.contains("No meeting matches"))
        XCTAssertEqual(self.run("meet", "list", "--since", "whenever").exitCode, 1)
        XCTAssertEqual(self.run("meet", "list", "--limit", "0").exitCode, 1)
        XCTAssertEqual(self.run("meet", "erase", "latest").exitCode, 1)
        XCTAssertEqual(self.run("meet", "search").exitCode, 1)
        XCTAssertEqual(self.run("dictate").exitCode, 1)
        XCTAssertEqual(self.run().exitCode, 0)
    }

    func testCommandNeverChangesTheMeetingsFolder() throws {
        let session = self.session(title: "Weekly sync")
        try self.save(session)
        let before = try self.snapshot()

        _ = self.run("meet", "list")
        _ = self.run("meet", "show", "latest", "--json")
        _ = self.run("meet", "search", "merged")
        _ = self.run("meet", "summary", "latest")
        _ = self.run("status")

        XCTAssertEqual(try self.snapshot(), before)
    }

    // MARK: - Skill

    func testSkillIsAddedUpdatedAndRemovedOnlyWhereItBelongs() throws {
        let agent = FluidServeSkillInstaller.Agent.claudeCode
        let tool = "/Applications/FluidVoice.app/Contents/Helpers/fv-serve"
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: self.home), .agentNotFound)

        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: self.home), .notInstalled)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: .codex, toolPath: tool, home: self.home), .agentNotFound)

        try FluidServeSkillInstaller.install(for: agent, toolPath: tool, home: self.home)
        let file = FluidServeSkillInstaller.skillFile(for: agent, home: self.home)
        XCTAssertEqual(file.path, self.home.path + "/.claude/skills/fluidmeet/SKILL.md")
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("---\nname: fluidmeet\ndescription: "))
        XCTAssertTrue(written.contains("\"\(tool)\" meet list"))
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: self.home), .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.home.appendingPathComponent(".codex").path), "Adding one tool's skill must not create the other tool's folder")

        let moved = "/Users/someone/Apps/FluidVoice.app/Contents/Helpers/fv-serve"
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: moved, home: self.home), .needsUpdate)
        try FluidServeSkillInstaller.install(for: agent, toolPath: moved, home: self.home)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: moved, home: self.home), .installed)

        try FluidServeSkillInstaller.remove(for: agent, home: self.home)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: moved, home: self.home), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertNoThrow(try FluidServeSkillInstaller.remove(for: agent, home: self.home), "Removing twice is harmless")
    }

    func testSomeoneElsesSkillOfTheSameNameIsLeftAlone() throws {
        let agent = FluidServeSkillInstaller.Agent.codex
        let file = FluidServeSkillInstaller.skillFile(for: agent, home: self.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = "---\nname: fluidmeet\ndescription: mine\n---\nHand written.\n"
        try Data(theirs.utf8).write(to: file)

        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: "/x/fv-serve", home: self.home), .foreign)
        XCTAssertThrowsError(try FluidServeSkillInstaller.install(for: agent, toolPath: "/x/fv-serve", home: self.home))
        XCTAssertThrowsError(try FluidServeSkillInstaller.remove(for: agent, home: self.home))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), theirs)
    }

    // MARK: - Fixtures

    private func run(_ arguments: String...) -> FluidServeCommand.Result {
        FluidServeCommand.run(
            arguments: arguments,
            root: self.root,
            accessEnabled: true,
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    private func directory(for session: MeetingSession) -> URL {
        self.root.appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    /// Writes the session the way the app's store does: ISO 8601 dates in `<id>/session.json`.
    private func save(_ session: MeetingSession) throws {
        let directory = self.directory(for: session)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
    }

    private func snapshot() throws -> [String: Date] {
        var result: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: self.root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            result[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return result
    }

    private func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64(seconds * 1000), timescale: 1000)
    }

    /// Three kept turns and one echo. One speaker was merged into Priya, and one turn has two voices.
    private func session(title: String, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: title,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
            ),
            startedAt: startedAt,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 1,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: self.mediaTime(0)
            )
        )
        let trackID = UUID()
        let priya = UUID()
        let marcus = UUID()
        let mergedAway = UUID()
        func speaker(_ id: UUID, _ name: String, mergedInto: UUID? = nil) -> MeetingSessionSpeaker {
            var speaker = MeetingSessionSpeaker(
                id: id,
                displayName: name,
                diarizationClusterID: nil,
                trackKind: .microphone,
                isLocalUser: false,
                identityCandidates: []
            )
            speaker.mergedIntoSpeakerID = mergedInto
            return speaker
        }
        func turn(_ start: TimeInterval, _ speakerID: UUID?, _ text: String) -> MeetingTranscriptSegment {
            MeetingTranscriptSegment(
                id: UUID(),
                start: self.mediaTime(start),
                end: self.mediaTime(start + 5),
                sourceTrackID: trackID,
                speakerID: speakerID,
                text: text,
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete
            )
        }
        session.speakers = [speaker(priya, "Priya"), speaker(marcus, "Marcus"), speaker(mergedAway, "Speaker 3", mergedInto: priya)]
        var echo = turn(12, marcus, "echo of the far side")
        echo.isLikelyEcho = true
        var overlapping = turn(30, nil, "two people at once")
        overlapping.attributionState = .overlappingSpeakers
        var assigned = turn(20, mergedAway, "merged speaker keeps the name")
        assigned.attributionState = .assigned
        session.transcriptSegments = [overlapping, turn(10, marcus, "first words"), echo, assigned]
        session.state = .completed
        session.endedAt = startedAt.addingTimeInterval(600)
        return session
    }
}
