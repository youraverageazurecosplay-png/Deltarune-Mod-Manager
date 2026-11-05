import Foundation

private struct DesktopLauncherConfiguration: Decodable {
    let managerAppPath: String
    let launchURL: String
}

@main
private struct DesktopModLauncher {
    static func main() {
        do {
            try launchMod()
        } catch {
            fputs("Could not launch mod: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func launchMod() throws {
        let configurationURL = Bundle.main.resourceURL?
            .appendingPathComponent("dmt-launch.plist")
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL) else {
            throw LauncherError.missingConfiguration
        }
        let configuration = try PropertyListDecoder().decode(
            DesktopLauncherConfiguration.self,
            from: data
        )
        guard let launchURL = URL(string: configuration.launchURL),
              launchURL.scheme == "dmt" else {
            throw LauncherError.invalidLaunchURL
        }

        let managerBundleID = "com.local.deltarune-mod-manager"
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        lookup.arguments = ["find", "bundleid=\(managerBundleID)"]
        let lookupOutput = Pipe()
        lookup.standardOutput = lookupOutput
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        let runningApps = lookupOutput.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if !runningApps.isEmpty {
            open.arguments = ["-g", "-b", managerBundleID, launchURL.absoluteString]
        } else {
            open.arguments = ["-a", configuration.managerAppPath, launchURL.absoluteString]
        }
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw LauncherError.openFailed(open.terminationStatus)
        }
    }
}

private enum LauncherError: LocalizedError {
    case missingConfiguration
    case invalidLaunchURL
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "The mod shortcut is missing its launch configuration."
        case .invalidLaunchURL:
            "The mod shortcut contains an invalid launch URL."
        case let .openFailed(status):
            "macOS could not open the mod manager (error \(status))."
        }
    }
}
