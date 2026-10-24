import Foundation

struct Service: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var repo: String
    var hostname: String?
    var hostPort: Int?
    var address: String?

    var directory: URL { Service.root.appendingPathComponent(name) }

    var wantsSSL: Bool {
        guard let hostname, hostname.contains(".") else { return false }
        return ![".test", ".localhost", ".local", ".internal", ".lan"].contains { hostname.hasSuffix($0) }
    }

    var logsDirectory: URL { Service.logsRoot.appendingPathComponent(name) }

    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".void")
    static let root = home.appendingPathComponent("services")
    static let certs = home.appendingPathComponent("certs")
    static let logsRoot = home.appendingPathComponent("logs")
    static let manifest = home.appendingPathComponent("services.json")
}

struct EditTarget: Codable, Hashable {
    var id: UUID?
}

struct ListeningPort: Hashable {
    var host: String
    var port: Int

    var label: String { "\(host):\(port)" }
    var url: URL? { URL(string: "http://localhost:\(port)") }
}
