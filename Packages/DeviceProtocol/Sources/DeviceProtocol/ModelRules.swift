import Foundation

/// Web command-routing quirks, independent of firmware feature flags. Missing
/// rules fail closed for model-specific writes; ModelCatalog validates this file.
enum ModelRules {
    static let loaded: Result<[String: Set<String>], any Error> = Result {
        guard let url = ProtocolResources.bundle.url(forResource: "model_rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([String: Set<String>].self, from: Data(contentsOf: url))
    }
    static func includes(_ rule: String, _ base: String) -> Bool {
        (try? loaded.get()[rule]?.contains(base)) ?? false
    }
}
