import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders }
    enum Preview { case meeting, dashboard, models }

    struct Feature: Identifiable {
        let id: String
        let preview: Preview
        let eyebrow: String
        let title: String
        let detail: String
        let action: String
        let destination: Destination
    }

    let release: String
    let title: String
    let subtitle: String
    let features: [Feature]

    static func current(hasPrivateAI: Bool) -> Self {
        Self(
            release: "1.6.12",
            title: "A smoother start.",
            subtitle: "More reliable startup and model downloads.",
            features: [
                Feature(
                    id: "startup",
                    preview: .dashboard,
                    eyebrow: "READY WHEN YOU ARE",
                    title: "Quieter login launches",
                    detail: "Keep the window hidden at login, then reopen it from the menu bar without a duplicate.",
                    action: "Open dashboard",
                    destination: .dashboard
                ),
                Feature(
                    id: "models",
                    preview: .models,
                    eyebrow: hasPrivateAI ? "ON YOUR MAC. FOR YOU." : "YOUR AI, YOUR WAY",
                    title: hasPrivateAI ? "More reliable downloads" : "Find your AI",
                    detail: hasPrivateAI
                        ? "Model downloads retry brief interruptions and resume saved progress. Working models stay available during a failed update."
                        : "Choose your AI provider and make every dictation sound more like you.",
                    action: hasPrivateAI ? "Explore the models" : "Explore AI providers",
                    destination: .aiProviders
                ),
            ]
        )
    }
}
