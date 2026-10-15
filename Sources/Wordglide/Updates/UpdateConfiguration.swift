import Foundation

/// The public feed and verification key are release metadata, never secrets.
struct UpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    init(info: [String: Any], bundleURL: URL) throws {
        guard bundleURL.pathExtension.lowercased() == "app",
              info["CFBundlePackageType"] as? String == "APPL" else {
            throw ConfigurationError.notApplication
        }
        guard let rawFeed = info["SUFeedURL"] as? String, !rawFeed.isEmpty else {
            throw ConfigurationError.missingFeed
        }
        guard let components = URLComponents(string: rawFeed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              !rawFeed.contains(where: { $0.isWhitespace }),
              let feedURL = components.url else {
            throw ConfigurationError.invalidFeed
        }
        guard let publicKey = info["SUPublicEDKey"] as? String, !publicKey.isEmpty else {
            throw ConfigurationError.missingPublicKey
        }
        guard let keyData = Data(base64Encoded: publicKey), keyData.count == 32 else {
            throw ConfigurationError.invalidPublicKey
        }
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    enum ConfigurationError: LocalizedError {
        case notApplication, missingFeed, invalidFeed, missingPublicKey, invalidPublicKey

        var errorDescription: String? {
            switch self {
            case .notApplication: return "自动更新仅在打包后的应用中启用。"
            case .missingFeed: return "尚未配置更新源。"
            case .invalidFeed: return "更新源配置无效，需要有效的 HTTPS 地址。"
            case .missingPublicKey: return "尚未配置更新签名公钥。"
            case .invalidPublicKey: return "更新签名公钥配置无效。"
            }
        }
    }
}
