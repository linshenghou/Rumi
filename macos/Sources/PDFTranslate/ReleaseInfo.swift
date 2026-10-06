import Foundation

/// The same checked-in resource drives SwiftPM, Info.plist and release filenames.
struct ReleaseInfo: Decodable {
    let product: String
    let version: String
    let build: String
    let channel: String
    let beta: Int
    let owner: String
    let repository: String

    static let current: ReleaseInfo = {
        let url = Bundle.main.url(forResource: "Release", withExtension: "json")
            ?? Bundle.module.url(forResource: "Release", withExtension: "json")!
        return try! JSONDecoder().decode(ReleaseInfo.self, from: Data(contentsOf: url))
    }()

    var displayVersion: String { "\(version) Beta \(beta)" }
    var bundleIdentifier: String { "io.github.\(owner.lowercased()).rumi" }
    var keychainService: String { bundleIdentifier + ".api-key" }
    var repositoryURL: URL { URL(string: "https://github.com/\(owner)/\(repository)")! }
    func url(_ path: String) -> URL { repositoryURL.appendingPathComponent(path) }
}
