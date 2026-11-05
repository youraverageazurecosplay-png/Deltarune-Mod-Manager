import Foundation

struct AppUpdateRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

enum AppUpdateError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse:
            "GitHub returned an unexpected response while checking for updates."
        }
    }
}

enum AppUpdateService {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/youraverageazurecosplay-png/DeltaruneModTool-for-Mac/releases/latest"
    )!

    static func latestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DELTARUNE-Mod-Manager", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw AppUpdateError.badResponse
        }
        return try JSONDecoder().decode(AppUpdateRelease.self, from: data)
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let latestParts = versionParts(latest),
              let currentParts = versionParts(current) else {
            return false
        }
        for index in 0..<max(latestParts.count, currentParts.count) {
            let latestPart = index < latestParts.count ? latestParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if latestPart != currentPart {
                return latestPart > currentPart
            }
        }
        return false
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        let parts = components.compactMap { Int($0) }
        return parts.count == components.count ? parts : nil
    }
}
