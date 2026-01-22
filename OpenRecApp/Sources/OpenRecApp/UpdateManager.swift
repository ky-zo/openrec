import Foundation

struct UpdateManager {
    struct Version: Comparable {
        let parts: [Int]

        init?(_ string: String) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
            let core = normalized.split(separator: "-").first.map(String.init) ?? normalized
            let partStrings = core.split(separator: ".")
            guard !partStrings.isEmpty else { return nil }

            var parsed: [Int] = []
            for part in partStrings {
                guard let number = Int(part) else { return nil }
                parsed.append(number)
            }

            parts = parsed
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let maxCount = max(lhs.parts.count, rhs.parts.count)
            for i in 0..<maxCount {
                let left = i < lhs.parts.count ? lhs.parts[i] : 0
                let right = i < rhs.parts.count ? rhs.parts[i] : 0
                if left != right {
                    return left < right
                }
            }
            return false
        }
    }

    struct UpdateInfo {
        let latestVersion: Version
        let tag: String
        let downloadURL: URL
    }

    private static let repoOwner = "ky-zo"
    private static let repoName = "openrec"
    private static let preferredAssetName = "OpenRec.dmg"
    private static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    )!

    static func checkForUpdate(currentVersion: String, completion: @escaping (UpdateInfo?) -> Void) {
        guard let current = Version(currentVersion) else {
            completion(nil)
            return
        }

        fetchLatestRelease { info in
            guard let info else {
                completion(nil)
                return
            }
            completion(info.latestVersion > current ? info : nil)
        }
    }

    static func downloadUpdate(from info: UpdateInfo, completion: @escaping (URL?) -> Void) {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let updatesDir = baseDir.appendingPathComponent("openrec/updates", isDirectory: true)

        do {
            try fileManager.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        } catch {
            completion(nil)
            return
        }

        let safeTag = info.tag.replacingOccurrences(of: "/", with: "-")
        let fileName = "OpenRec-\(safeTag).dmg"
        let destinationURL = updatesDir.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            completion(destinationURL)
            return
        }

        let task = URLSession.shared.downloadTask(with: info.downloadURL) { tempURL, _, error in
            guard error == nil, let tempURL else {
                completion(nil)
                return
            }

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                completion(destinationURL)
            } catch {
                completion(nil)
            }
        }

        task.resume()
    }

    private static func fetchLatestRelease(completion: @escaping (UpdateInfo?) -> Void) {
        var request = URLRequest(url: releaseAPIURL)
        request.timeoutInterval = 5
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenRec", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil else {
                completion(nil)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(nil)
                return
            }
            guard let data else {
                completion(nil)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            guard let tag = json["tag_name"] as? String else {
                completion(nil)
                return
            }
            guard let latestVersion = Version(tag) else {
                completion(nil)
                return
            }

            var downloadURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                if let preferred = assets.first(where: { ($0["name"] as? String) == preferredAssetName }) {
                    if let urlString = preferred["browser_download_url"] as? String {
                        downloadURL = URL(string: urlString)
                    }
                }

                if downloadURL == nil {
                    if let dmgAsset = assets.first(where: {
                        guard let name = $0["name"] as? String else { return false }
                        return name.lowercased().hasSuffix(".dmg")
                    }) {
                        if let urlString = dmgAsset["browser_download_url"] as? String {
                            downloadURL = URL(string: urlString)
                        }
                    }
                }
            }

            guard let downloadURL else {
                completion(nil)
                return
            }

            completion(UpdateInfo(latestVersion: latestVersion, tag: tag, downloadURL: downloadURL))
        }

        task.resume()
    }
}

extension Bundle {
    var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
