import Foundation
import AppKit
import Observation

@Observable final class ServiceStore {
    var services: [Service] = []
    var running: Set<UUID> = []
    var updates: Set<UUID> = []
    var busy: Set<UUID> = []
    var logs: [UUID: String] = [:]
    var ports: [UUID: [ListeningPort]] = [:]
    var error: String?

    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let proxy = TLSProxy()
    @ObservationIgnored private var portTimer: Timer?

    init() {
        load()
        checkUpdates()
        Task { await verifyBindings() }
        portTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanPorts() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUpdates() }
        }
    }

    private func scanPorts() {
        for (id, process) in processes {
            let pgid = process.processIdentifier
            Task {
                let result = await shell("lsof -nP -a -g \(pgid) -iTCP -sTCP:LISTEN -Fn")
                var found: [ListeningPort] = []
                for line in result.output.split(separator: "\n") where line.hasPrefix("n") {
                    let address = line.dropFirst()
                    guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { continue }
                    let host = String(address[..<colon])
                    let shown = ["127.0.0.1", "[::1]", "localhost"].contains(host) ? "localhost" : "0.0.0.0"
                    let entry = ListeningPort(host: shown, port: port)
                    if !found.contains(entry) { found.append(entry) }
                }
                found.sort { $0.port < $1.port }
                guard processes[id] != nil else { return }
                if ports[id] != found { ports[id] = found }
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Service.manifest) else { return }
        services = (try? JSONDecoder().decode([Service].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Service.home, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(services) { try? data.write(to: Service.manifest) }
    }

    func add(name: String, command: String, repo: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !services.contains(where: { $0.name == name }) else {
            error = "Invalid or duplicate name"
            return false
        }
        let service = Service(name: name, command: command, repo: repo)
        try? FileManager.default.createDirectory(at: Service.root, withIntermediateDirectories: true)
        busy.insert(service.id)
        defer { busy.remove(service.id) }
        let result = await shell("git clone \(quoted(repo)) \(quoted(service.directory.path))")
        guard result.status == 0 else {
            error = result.output
            return false
        }
        error = nil
        services.append(service)
        save()
        return true
    }

    func update(_ service: Service, name: String, command: String, repo: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return false }
        let renamed = name != service.name
        if renamed {
            guard !name.isEmpty, !name.contains("/"), !services.contains(where: { $0.name == name }) else {
                error = "Invalid or duplicate name"
                return false
            }
            guard !running.contains(service.id) else {
                error = "Stop the service before renaming"
                return false
            }
        }
        var updated = service
        updated.name = name
        updated.command = command
        updated.repo = repo
        if renamed {
            do {
                try FileManager.default.moveItem(at: service.directory, to: updated.directory)
                if FileManager.default.fileExists(atPath: service.logsDirectory.path) {
                    try FileManager.default.moveItem(at: service.logsDirectory, to: updated.logsDirectory)
                }
            } catch {
                self.error = error.localizedDescription
                return false
            }
        }
        if repo != service.repo {
            let result = await shell("git remote set-url origin \(quoted(repo))", in: updated.directory)
            guard result.status == 0 else {
                error = result.output
                return false
            }
        }
        error = nil
        services[index] = updated
        save()
        checkUpdates()
        return true
    }

    private func bindingScript(_ list: [Service], removing: [String]) -> String {
        var lines = ["#!/bin/sh", "set -e", "sed -i '' '/# void$/d' /etc/hosts"]
        for address in removing { lines.append("ifconfig lo0 -alias \(address) 2>/dev/null || true") }
        var rules: [String] = []
        for service in list {
            guard let hostname = service.hostname, let port = service.hostPort, let address = service.address else { continue }
            lines.append("ifconfig lo0 alias \(address) up")
            lines.append("echo '\(address) \(hostname) # void' >> /etc/hosts")
            rules.append("rdr pass on lo0 inet proto tcp from any to \(address) port 80 -> 127.0.0.1 port \(TLSProxy.httpPort(for: address))")
            if service.wantsSSL {
                rules.append("rdr pass on lo0 inet proto tcp from any to \(address) port 443 -> 127.0.0.1 port \(TLSProxy.proxyPort(for: address))")
            }
        }
        if rules.isEmpty {
            lines.append("pfctl -a com.apple/void -F all 2>/dev/null || true")
        } else {
            lines.append("pfctl -a com.apple/void -f - <<'EOF'")
            lines += rules
            lines.append("EOF")
            lines.append("pfctl -E 2>/dev/null || true")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func applyBindings(_ list: [Service], removing: [String]) async -> Bool {
        try? FileManager.default.createDirectory(at: Service.home, withIntermediateDirectories: true)
        let script = Service.home.appendingPathComponent("apply.sh")
        let applied = Service.home.appendingPathComponent("applied.sh")
        try? bindingScript(list, removing: removing).write(to: script, atomically: true, encoding: .utf8)
        let result = await shell("osascript -e " + quoted("do shell script \"/bin/sh " + quoted(script.path) + "\" with administrator privileges"))
        if result.status != 0 { error = result.output }
        else { try? bindingScript(list, removing: []).write(to: applied, atomically: true, encoding: .utf8) }
        return result.status == 0
    }

    private func ensureCertificate(for hostname: String) async -> Bool {
        let dir = Service.certs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent("ca.pem").path) {
            let config = "[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=void local CA\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
            try? config.write(to: dir.appendingPathComponent("ca.cnf"), atomically: true, encoding: .utf8)
            let result = await shell("/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 3650 -config ca.cnf", in: dir)
            guard result.status == 0 else { error = result.output; return false }
        }
        if !fm.fileExists(atPath: dir.appendingPathComponent("\(hostname).p12").path) {
            let config = "[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=\(hostname)\n[v3]\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:\(hostname)\n"
            try? config.write(to: dir.appendingPathComponent("\(hostname).cnf"), atomically: true, encoding: .utf8)
            let h = hostname
            let result = await shell("/usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout \(h).key -out \(h).csr -config \(h).cnf && /usr/bin/openssl x509 -req -in \(h).csr -CA ca.pem -CAkey ca.key -CAcreateserial -out \(h).pem -days 825 -extfile \(h).cnf -extensions v3 && /usr/bin/openssl pkcs12 -export -inkey \(h).key -in \(h).pem -out \(h).p12 -passout pass:void", in: dir)
            guard result.status == 0 else { error = result.output; return false }
        }
        return true
    }

    private func ensureTrusted(_ hostname: String) async -> Bool {
        let dir = Service.certs
        let check = "/usr/bin/security verify-cert -c \(quoted(dir.appendingPathComponent("\(hostname).pem").path)) -p ssl -s \(hostname)"
        if await shell(check).status == 0 { return true }
        let keychain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
        let result = await shell("/usr/bin/security add-trusted-cert -r trustRoot -k \(quoted(keychain)) \(quoted(dir.appendingPathComponent("ca.pem").path))")
        if result.status != 0 { error = result.output }
        return result.status == 0
    }

    private func startProxy(_ service: Service) {
        guard let hostname = service.hostname, let address = service.address, let port = service.hostPort else {
            proxy.stop(id: service.id)
            return
        }
        proxy.stop(id: service.id)
        proxy.start(id: service.id, address: address, identityFile: nil, targetPort: port, label: hostname)
        if service.wantsSSL {
            proxy.start(id: service.id, address: address, identityFile: Service.certs.appendingPathComponent("\(hostname).p12"), targetPort: port, label: hostname)
        }
    }

    func verifyBindings() async {
        let bound = services.filter { $0.address != nil && $0.hostname != nil }
        guard !bound.isEmpty else { return }
        for service in bound {
            if service.wantsSSL, let hostname = service.hostname {
                guard await ensureCertificate(for: hostname) else { continue }
                _ = await ensureTrusted(hostname)
            }
            startProxy(service)
        }
        let current = await shell("ifconfig lo0").output
        let applied = try? String(contentsOf: Service.home.appendingPathComponent("applied.sh"), encoding: .utf8)
        if applied != bindingScript(services, removing: []) || bound.contains(where: { !current.contains("inet \($0.address ?? "") ") }) {
            _ = await applyBindings(services, removing: [])
        }
    }

    func bind(_ service: Service, hostname: String, port: Int) async -> Bool {
        let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hostname.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil, (1...65535).contains(port) else {
            error = "Invalid hostname or port"
            return false
        }
        guard !services.contains(where: { $0.id != service.id && $0.hostname == hostname }) else {
            error = "Hostname already bound to another service"
            return false
        }
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return false }
        var updated = services[index]
        let used = Set(services.compactMap(\.address))
        let address = updated.address ?? (2...254).map { "127.0.0.\($0)" }.first { !used.contains($0) }
        guard let address else { return false }
        updated.hostname = hostname
        updated.hostPort = port
        updated.address = address
        if updated.wantsSSL {
            guard await ensureCertificate(for: hostname), await ensureTrusted(hostname) else { return false }
        }
        var next = services
        next[index] = updated
        guard await applyBindings(next, removing: []) else { return false }
        error = nil
        services = next
        save()
        startProxy(updated)
        return true
    }

    func unbind(_ service: Service) async -> Bool {
        guard let index = services.firstIndex(where: { $0.id == service.id }), let address = services[index].address else { return true }
        var next = services
        next[index].hostname = nil
        next[index].hostPort = nil
        next[index].address = nil
        guard await applyBindings(next, removing: [address]) else { return false }
        proxy.stop(id: service.id)
        error = nil
        services = next
        save()
        return true
    }

    func remove(_ service: Service) {
        stop(service)
        proxy.stop(id: service.id)
        services.removeAll { $0.id == service.id }
        save()
    }

    func start(_ service: Service) {
        guard processes[service.id] == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0,0); exec @ARGV", "/bin/zsh", "-lic", service.command]
        process.currentDirectoryURL = service.directory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let id = service.id

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        try? FileManager.default.createDirectory(at: service.logsDirectory, withIntermediateDirectories: true)
        let logURL = service.logsDirectory.appendingPathComponent(formatter.string(from: Date()) + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let file = try? FileHandle(forWritingTo: logURL)

        let append: @Sendable (String) -> Void = { [weak self] text in
            try? file?.write(contentsOf: Data(text.utf8))
            DispatchQueue.main.async { self?.logs[id, default: ""] += text }
        }
        append("$ \(service.command)\n[cwd \(service.directory.path)]\n\n")

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.availableData
            if !rest.isEmpty { append(String(decoding: rest, as: UTF8.self)) }
            append("\n[exited with status \(proc.terminationStatus)]\n")
            try? file?.close()
            DispatchQueue.main.async {
                self?.processes[id] = nil
                self?.ports[id] = nil
                self?.running.remove(id)
            }
        }
        logs[id] = ""
        do {
            try process.run()
            processes[id] = process
            running.insert(id)
        } catch {
            append("[failed to launch: \(error.localizedDescription)]\n")
            try? file?.close()
        }
    }

    func recentLogs(_ service: Service) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: service.logsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(10).map { $0 }
    }

    func open(port: ListeningPort) {
        if let url = port.url { NSWorkspace.shared.open(url) }
    }

    func open(log: URL) {
        NSWorkspace.shared.open(log)
    }

    private func tree(of root: Int32) async -> [Int32] {
        let rows = await shell("/bin/ps -axo pid=,ppid=,pgid=").output.split(separator: "\n").compactMap { line -> (Int32, Int32, Int32)? in
            let parts = line.split(separator: " ").compactMap { Int32($0) }
            return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
        }
        var found: Set<Int32> = [root]
        var grew = true
        while grew {
            grew = false
            for (pid, ppid, pgid) in rows where !found.contains(pid) && (found.contains(ppid) || pgid == root) {
                found.insert(pid)
                grew = true
            }
        }
        return Array(found)
    }

    func stop(_ service: Service) {
        guard let process = processes[service.id] else { return }
        let root = process.processIdentifier
        Task {
            let pids = await tree(of: root)
            for pid in pids { kill(pid, SIGTERM) }
            try? await Task.sleep(for: .seconds(2))
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    func checkUpdates() {
        for service in services {
            Task {
                let fetch = await shell("git fetch --quiet", in: service.directory)
                guard fetch.status == 0 else { return }
                let behind = await shell("git rev-list --count HEAD..@{u}", in: service.directory)
                if Int(behind.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0 {
                    updates.insert(service.id)
                } else {
                    updates.remove(service.id)
                }
            }
        }
    }

    func pull(_ service: Service) {
        busy.insert(service.id)
        Task {
            let result = await shell("git pull", in: service.directory)
            busy.remove(service.id)
            if result.status != 0 { error = result.output }
            else { updates.remove(service.id) }
        }
    }

    func openInFinder(_ service: Service) {
        NSWorkspace.shared.open(service.directory)
    }

    func openInTerminal(_ service: Service) {
        NSWorkspace.shared.open(
            [service.directory],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
