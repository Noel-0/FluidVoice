import Foundation

// `fv-serve` ships inside FluidVoice.app/Contents/Helpers. It answers one question and exits:
// no server, no model, no audio. The switch that allows it lives in the app's own preferences.

/// The bundle identifier of the app this copy shipped in, so Debug and release builds each read their own switch.
func enclosingAppBundleIdentifier() -> String {
    // The real location of this program, not the name it was started by: `argv[0]` is just
    // "fv-serve" when it is found through PATH or a symlink.
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let infoPlist = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist", isDirectory: false)
    if let info = NSDictionary(contentsOf: infoPlist), let identifier = info["CFBundleIdentifier"] as? String {
        return identifier
    }
    return FluidServeMeetings.releaseBundleIdentifier
}

let result = FluidServeCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    root: FluidServeMeetings.defaultRoot(),
    accessEnabled: FluidServeMeetings.isAccessEnabled(bundleIdentifier: enclosingAppBundleIdentifier())
)
let stream = result.exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError
stream.write(Data((result.output + "\n").utf8))
exit(result.exitCode)
