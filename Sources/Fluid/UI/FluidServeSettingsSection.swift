import AppKit
import Combine
import SwiftUI

/// Tracks where the `fluidmeet` skill is installed and whether `fv-serve` really answers.
/// File checks, writes and the command run happen off the main thread, and only when the
/// section appears, the switch changes or the user presses a button; nothing polls.
@MainActor
final class FluidServeSettingsModel: ObservableObject {
    typealias Agent = FluidServeSkillInstaller.Agent
    typealias Status = FluidServeSkillInstaller.Status

    /// What the last button press did, shown under that row until the next press.
    enum Notice: Equatable {
        case added
        case updated
        case removed
    }

    @Published private(set) var statuses: [Agent: Status] = [:]
    @Published private(set) var notices: [Agent: Notice] = [:]
    @Published private(set) var toolIsBundled = true
    /// Whether an app on this Mac opens `codex://` links, so the row can offer to start a chat.
    @Published private(set) var codexAppIsInstalled = false
    /// The answer from running the real command. Nil while access is off or before the first run.
    @Published private(set) var check: FluidServeSelfCheck.Outcome?
    @Published private(set) var isChecking = false
    @Published private(set) var issue: String?

    private let home: URL
    private let toolURL: () -> URL?
    private let selfCheck: @Sendable (URL) -> FluidServeSelfCheck.Outcome

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolURL: @escaping () -> URL? = { FluidServeSkillInstaller.bundledToolURL() },
        selfCheck: @escaping @Sendable (URL) -> FluidServeSelfCheck.Outcome = { FluidServeSelfCheck.run(tool: $0) }
    ) {
        self.home = home
        self.toolURL = toolURL
        self.selfCheck = selfCheck
    }

    func skillFolder(for agent: Agent) -> URL {
        FluidServeSkillInstaller.skillFile(for: agent, home: self.home).deletingLastPathComponent()
    }

    /// `accessEnabled` is the switch as the page shows it; the command is only run while it is on.
    func refresh(accessEnabled: Bool) async {
        let home = self.home
        let tool = self.toolURL()
        let selfCheck = self.selfCheck
        self.toolIsBundled = tool != nil
        self.isChecking = accessEnabled && tool != nil
        let codexLink = FluidServeSkillInstaller.codexNewChatURL()
        let found = await Task.detached(priority: .utility) {
            let statuses = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
                (agent, FluidServeSkillInstaller.status(for: agent, toolPath: tool?.path ?? "", home: home))
            })
            let codexApp = codexLink.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            let check = accessEnabled ? tool.map(selfCheck) : nil
            return (statuses, codexApp != nil, check)
        }.value
        self.statuses = found.0
        self.codexAppIsInstalled = found.1
        self.check = found.2
        self.isChecking = false
    }

    /// Opens a new Codex chat with a starter prompt typed in. The user still presses send.
    func openCodexChat() {
        guard let url = FluidServeSkillInstaller.codexNewChatURL() else { return }
        if !NSWorkspace.shared.open(url) {
            self.issue = "Could not open Codex."
        }
    }

    func revealSkill(for agent: Agent) {
        NSWorkspace.shared.activateFileViewerSelecting([FluidServeSkillInstaller.skillFile(for: agent, home: self.home)])
    }

    func install(_ agent: Agent, accessEnabled: Bool) async {
        guard let tool = self.toolURL() else {
            self.issue = FluidServeSkillInstaller.InstallError.toolMissing.localizedDescription
            return
        }
        let wasPresent = self.statuses[agent] == .needsUpdate
        await self.change(agent, notice: wasPresent ? .updated : .added, expecting: .installed, accessEnabled: accessEnabled) { home in
            try FluidServeSkillInstaller.install(for: agent, toolPath: tool.path, home: home)
        }
    }

    func remove(_ agent: Agent, accessEnabled: Bool) async {
        await self.change(agent, notice: .removed, expecting: .notInstalled, accessEnabled: accessEnabled) { home in
            try FluidServeSkillInstaller.remove(for: agent, home: home)
        }
    }

    /// Does the work, re-reads the disk, and only then says it worked: the notice is shown when the
    /// file is really in the state the button promised.
    private func change(
        _ agent: Agent,
        notice: Notice,
        expecting expected: Status,
        accessEnabled: Bool,
        _ work: @escaping @Sendable (URL) throws -> Void
    ) async {
        let home = self.home
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try work(home)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        await self.refresh(accessEnabled: accessEnabled)
        if failure == nil, self.statuses[agent] == expected {
            self.notices[agent] = notice
            self.issue = nil
        } else {
            self.notices[agent] = nil
            self.issue = failure ?? "\(agent.displayName): the skill file is not in the expected place. Nothing was confirmed."
        }
    }
}

/// Experimental: lets Claude Code and Codex read saved meetings through the bundled `fv-serve` command.
struct FluidServeSettingsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: FluidServeSettingsModel
    @State private var accessEnabled: Bool

    init(model: FluidServeSettingsModel? = nil, accessEnabled: Bool? = nil) {
        _model = StateObject(wrappedValue: model ?? FluidServeSettingsModel())
        _accessEnabled = State(initialValue: accessEnabled ?? SettingsStore.shared.fluidServeMeetingAccessEnabled)
    }

    private var secondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fluid Server")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Text("Let Claude Code and Codex read your meetings: transcripts, saved summaries and search.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Fluid Server", isOn: Binding(
                    get: { self.accessEnabled },
                    set: { newValue in
                        self.accessEnabled = newValue
                        SettingsStore.shared.fluidServeMeetingAccessEnabled = newValue
                        Task { await self.model.refresh(accessEnabled: newValue) }
                    }
                ))
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
                .accessibilityLabel("Fluid Server")
            }

            Text("Off by default. Read-only, and nothing runs in the background. Claude Code and Codex are cloud tools: a meeting they read is sent to them.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if self.accessEnabled {
                if self.model.toolIsBundled {
                    self.checkLine
                    ForEach(FluidServeSkillInstaller.Agent.allCases) { agent in
                        self.row(for: agent)
                    }
                } else {
                    self.statusLabel(FluidServeSkillInstaller.InstallError.toolMissing.localizedDescription, symbol: "exclamationmark.circle.fill", color: .orange)
                }
                if let issue = self.model.issue {
                    self.statusLabel(issue, symbol: "exclamationmark.circle.fill", color: .orange)
                        .textSelection(.enabled)
                }
            }
        }
        .task { await self.model.refresh(accessEnabled: self.accessEnabled) }
    }

    /// Proof from running the real command, not from the switch position.
    @ViewBuilder
    private var checkLine: some View {
        switch self.model.check {
        case let .working(meetings):
            self.statusLabel(
                meetings == 1 ? "fv-serve is working: 1 meeting ready to read." : "fv-serve is working: \(meetings) meetings ready to read.",
                symbol: "checkmark.circle.fill",
                color: Color.fluidGreen
            )
        case .accessOff:
            self.statusLabel("fv-serve still reports meeting access as off. Turn the switch off and on again.", symbol: "exclamationmark.circle.fill", color: .orange)
        case let .failed(reason):
            self.statusLabel(reason, symbol: "exclamationmark.circle.fill", color: .orange)
        case nil:
            self.statusLabel(self.model.isChecking ? "Checking fv-serve…" : "fv-serve has not been checked yet.", symbol: "arrow.triangle.2.circlepath", color: self.secondaryText)
        }
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(for agent: FluidServeSkillInstaller.Agent) -> some View {
        let status = self.model.statuses[agent]
        let state = Self.state(for: status)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(agent.displayName)
                    .font(self.theme.typography.body)
                    .foregroundStyle(Color(nsColor: .labelColor))
                Label(state.title, systemImage: state.symbol)
                    .font(self.theme.typography.bodySmall.weight(.semibold))
                    .foregroundStyle(self.color(for: state.tone))
                    .accessibilityLabel("\(agent.displayName): \(state.title)")
                Spacer(minLength: 0)
                switch status {
                case .notInstalled:
                    Button("Add skill") { Task { await self.model.install(agent, accessEnabled: self.accessEnabled) } }
                        .fluidGlassAction(prominent: true)
                case .needsUpdate:
                    Button("Update skill") { Task { await self.model.install(agent, accessEnabled: self.accessEnabled) } }
                        .fluidGlassAction(prominent: true)
                    Button("Remove skill") { Task { await self.model.remove(agent, accessEnabled: self.accessEnabled) } }
                        .fluidGlassAction()
                case .installed:
                    if agent == .codex, self.model.codexAppIsInstalled {
                        Button("Open Codex") { self.model.openCodexChat() }
                            .fluidGlassAction(prominent: true)
                            .help("Starts a new Codex chat with a first question typed in. Nothing is sent until you send it.")
                    }
                    Button("Remove skill") { Task { await self.model.remove(agent, accessEnabled: self.accessEnabled) } }
                        .fluidGlassAction()
                case .agentNotFound, .foreign, nil:
                    EmptyView()
                }
            }

            HStack(spacing: 6) {
                Text(Self.detail(for: status, notice: self.model.notices[agent], agent: agent, folder: self.model.skillFolder(for: agent)))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if status == .installed || status == .needsUpdate || status == .foreign {
                    Button("Show in Finder") { self.model.revealSkill(for: agent) }
                        .buttonStyle(.link)
                        .font(self.theme.typography.bodySmall)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func color(for tone: Tone) -> Color {
        switch tone {
        case .good: return Color.fluidGreen
        case .attention: return .orange
        case .neutral: return self.secondaryText
        }
    }

    enum Tone: Equatable {
        case good
        case attention
        case neutral
    }

    /// The word and mark next to each tool's name: the state, never the next action.
    static func state(for status: FluidServeSkillInstaller.Status?) -> (title: String, symbol: String, tone: Tone) {
        switch status {
        case nil: return ("Checking…", "arrow.triangle.2.circlepath", .neutral)
        case .agentNotFound: return ("Not on this Mac", "minus.circle", .neutral)
        case .notInstalled: return ("Not added", "circle", .neutral)
        case .installed: return ("Skill added", "checkmark.circle.fill", .good)
        case .needsUpdate: return ("Needs update", "exclamationmark.circle.fill", .attention)
        case .foreign: return ("Different skill found", "exclamationmark.circle.fill", .attention)
        }
    }

    static func detail(
        for status: FluidServeSkillInstaller.Status?,
        notice: FluidServeSettingsModel.Notice?,
        agent: FluidServeSkillInstaller.Agent,
        folder: URL
    ) -> String {
        let skill = FluidServeSkillInstaller.skillName
        let place = (folder.path as NSString).abbreviatingWithTildeInPath
        switch status {
        case nil: return "Looking for the \(skill) skill…"
        case .agentNotFound: return "\(agent.displayName) has not been set up, so there is nowhere to add the skill."
        case .notInstalled:
            return notice == .removed ? "Removed just now. \(agent.displayName) no longer has the \(skill) skill." : "\(agent.displayName) does not have the \(skill) skill yet."
        case .installed:
            let lead = notice == .added ? "Added just now" : notice == .updated ? "Updated just now" : "Installed"
            return "\(lead) at \(place). Start a new \(agent.displayName) session and ask about a meeting."
        case .needsUpdate: return "The skill at \(place) is from an older or moved copy of FluidVoice."
        case .foreign: return "A \(skill) skill that FluidVoice did not write is at \(place). FluidVoice will not replace it."
        }
    }
}
