import AppKit
import Combine
import SwiftUI

/// Tracks where the `fluidmeet` skill is installed. File checks and writes run off the main thread
/// and only when the section appears or the user presses a button; nothing polls.
@MainActor
final class FluidServeSettingsModel: ObservableObject {
    typealias Agent = FluidServeSkillInstaller.Agent
    typealias Status = FluidServeSkillInstaller.Status

    @Published private(set) var statuses: [Agent: Status] = [:]
    @Published private(set) var toolIsBundled = true
    /// Whether an app on this Mac opens `codex://` links, so the row can offer to start a chat.
    @Published private(set) var codexAppIsInstalled = false
    @Published private(set) var issue: String?

    private let home: URL
    private let toolURL: () -> URL?

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolURL: @escaping () -> URL? = { FluidServeSkillInstaller.bundledToolURL() }
    ) {
        self.home = home
        self.toolURL = toolURL
    }

    func refresh() async {
        let home = self.home
        let tool = self.toolURL()
        self.toolIsBundled = tool != nil
        let codexLink = FluidServeSkillInstaller.codexNewChatURL()
        let found = await Task.detached(priority: .utility) {
            let statuses = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
                (agent, FluidServeSkillInstaller.status(for: agent, toolPath: tool?.path ?? "", home: home))
            })
            let codexApp = codexLink.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            return (statuses, codexApp != nil)
        }.value
        self.statuses = found.0
        self.codexAppIsInstalled = found.1
    }

    /// Opens a new Codex chat with a starter prompt typed in. The user still presses send.
    func openCodexChat() {
        guard let url = FluidServeSkillInstaller.codexNewChatURL() else { return }
        if !NSWorkspace.shared.open(url) {
            self.issue = "Could not open Codex."
        }
    }

    func install(_ agent: Agent) async {
        guard let tool = self.toolURL() else {
            self.issue = FluidServeSkillInstaller.InstallError.toolMissing.localizedDescription
            return
        }
        await self.change { home in try FluidServeSkillInstaller.install(for: agent, toolPath: tool.path, home: home) }
    }

    func remove(_ agent: Agent) async {
        await self.change { home in try FluidServeSkillInstaller.remove(for: agent, home: home) }
    }

    private func change(_ work: @escaping @Sendable (URL) throws -> Void) async {
        let home = self.home
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try work(home)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        self.issue = failure
        await self.refresh()
    }
}

/// Experimental: lets Claude Code and Codex read saved meetings through the bundled `fv-serve` command.
struct FluidServeSettingsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = FluidServeSettingsModel()
    @State private var accessEnabled = SettingsStore.shared.fluidServeMeetingAccessEnabled

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
                    ForEach(FluidServeSkillInstaller.Agent.allCases) { agent in
                        self.row(for: agent)
                    }
                } else {
                    Text(FluidServeSkillInstaller.InstallError.toolMissing.localizedDescription)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let issue = self.model.issue {
                    Text(issue)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .task { await self.model.refresh() }
    }

    private func row(for agent: FluidServeSkillInstaller.Agent) -> some View {
        let status = self.model.statuses[agent]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(self.theme.typography.body)
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(Self.detail(for: status, agent: agent))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            switch status {
            case .notInstalled:
                Button("Add skill") { Task { await self.model.install(agent) } }
                    .fluidGlassAction(prominent: true)
            case .needsUpdate:
                Button("Update") { Task { await self.model.install(agent) } }
                    .fluidGlassAction(prominent: true)
                Button("Remove") { Task { await self.model.remove(agent) } }
                    .fluidGlassAction()
            case .installed:
                if agent == .codex, self.model.codexAppIsInstalled {
                    Button("Open Codex") { self.model.openCodexChat() }
                        .fluidGlassAction(prominent: true)
                        .help("Starts a new Codex chat with a first question typed in. Nothing is sent until you send it.")
                }
                Button("Remove") { Task { await self.model.remove(agent) } }
                    .fluidGlassAction()
            case .agentNotFound, .foreign, nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func detail(for status: FluidServeSkillInstaller.Status?, agent: FluidServeSkillInstaller.Agent) -> String {
        switch status {
        case nil: return "Checking…"
        case .agentNotFound: return "Not set up on this Mac."
        case .notInstalled: return "Adds the \(FluidServeSkillInstaller.skillName) skill."
        case .installed: return "\(FluidServeSkillInstaller.skillName) skill added. Ask about a meeting in a new session."
        case .needsUpdate: return "The \(FluidServeSkillInstaller.skillName) skill is from an older or moved copy of FluidVoice."
        case .foreign: return "Another \(FluidServeSkillInstaller.skillName) skill is already there. FluidVoice will not replace it."
        }
    }
}
