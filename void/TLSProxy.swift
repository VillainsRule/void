import Foundation
import Network
import Security

nonisolated final class TLSProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "void.tls")
    private let lock = NSLock()
    private var listeners: [String: NWListener] = [:]

    static func proxyPort(for address: String) -> Int {
        18000 + octet(address)
    }

    static func httpPort(for address: String) -> Int {
        20000 + octet(address)
    }

    private static func octet(_ address: String) -> Int {
        Int(address.split(separator: ".").last ?? "") ?? 0
    }

    func start(id: UUID, address: String, identityFile: URL?, targetPort: Int, label: String) {
        let secure = identityFile != nil
        stop(id: id, secure: secure)
        guard let target = NWEndpoint.Port(rawValue: UInt16(targetPort)),
              let local = NWEndpoint.Port(rawValue: UInt16(secure ? Self.proxyPort(for: address) : Self.httpPort(for: address)))
        else { return }
        var params = NWParameters.tcp
        if let identityFile {
            guard let data = try? Data(contentsOf: identityFile) else { return }
            var items: CFArray?
            let options = [kSecImportExportPassphrase as String: "void", kSecImportToMemoryOnly as String: true] as CFDictionary
            guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
                  let first = (items as? [[String: Any]])?.first,
                  let identity = first[kSecImportItemIdentity as String],
                  let secIdentity = sec_identity_create(identity as! SecIdentity)
            else { return }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: local)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [self] inbound in
            let outbound = NWConnection(host: "localhost", port: target, using: .tcp)
            let settled = Settled()
            outbound.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard settled.claim() else { return }
                    pipe(inbound, outbound)
                    pipe(outbound, inbound)
                case .waiting, .failed:
                    guard settled.claim() else { return }
                    outbound.cancel()
                    respondBadGateway(inbound, label: label)
                default:
                    break
                }
            }
            inbound.start(queue: queue)
            outbound.start(queue: queue)
        }
        listener.start(queue: queue)
        lock.withLock { listeners[key(id, secure)] = listener }
    }

    func stop(id: UUID) {
        stop(id: id, secure: true)
        stop(id: id, secure: false)
    }

    private func stop(id: UUID, secure: Bool) {
        lock.withLock { listeners.removeValue(forKey: key(id, secure)) }?.cancel()
    }

    private func key(_ id: UUID, _ secure: Bool) -> String {
        "\(id)-\(secure)"
    }

    private func respondBadGateway(_ inbound: NWConnection, label: String) {
        let body = """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>502 Bad Gateway</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:100vh;margin:0;background:#111;color:#eee}main{text-align:center}h1{font-size:64px;margin:0}p{color:#999}small{color:#666}</style>
        <main><h1>502</h1><p>Bad Gateway</p><p>\(label) isn't running.</p><small>void</small></main>
        """
        let head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        inbound.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in inbound.cancel() })
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, finished, error in
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if error != nil {
                from.cancel()
                to.cancel()
            } else if finished {
                to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            } else {
                pipe(from, to)
            }
        }
    }
}

nonisolated final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
