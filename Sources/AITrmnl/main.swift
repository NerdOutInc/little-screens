import AppKit
import Foundation
import Darwin
import TRMNLCore

struct LaunchOptions {
    var host: String?
    var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI TRMNL")
    var agentPort: UInt16 = 8788
    var devicePort: UInt16 = 8787
    var refresh = 60
    var headless = false
    var ephemeral = false

    init() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            if argument == "--headless" { headless = true; continue }
            if argument == "--ephemeral" { ephemeral = true; continue }
            if argument == "--help" {
                print("""
                AI TRMNL 0.1.0 — a small local server with good reading comprehension.
                Usage: ai-trmnl [--headless] [--device-host IPv4] [--device-port 8787]
                                [--agent-port 8788] [--refresh-seconds 60] [--data-dir PATH]
                                [--ephemeral]
                Default: menu bar app. Help opens the starter page in your default browser.
                --headless runs in this terminal. --ephemeral uses temporary storage and no Keychain.
                Use the displayed LAN address for devices, and localhost for the agent page.
                """)
                exit(0)
            }
            guard !arguments.isEmpty else { throw NSError(domain: "Missing value for \(argument)", code: 1) }
            let value = arguments.removeFirst()
            switch argument {
            case "--device-host": host = value
            case "--data-dir": directory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--agent-port": guard let port = UInt16(value), port > 0 else { throw NSError(domain: "Invalid agent port", code: 1) }; agentPort = port
            case "--device-port": guard let port = UInt16(value), port > 0 else { throw NSError(domain: "Invalid device port", code: 1) }; devicePort = port
            case "--refresh-seconds": guard let seconds = Int(value) else { throw NSError(domain: "Invalid refresh interval", code: 1) }; refresh = seconds
            default: throw NSError(domain: "Unknown option: \(argument)", code: 1)
            }
        }
        if ephemeral { directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-trmnl-\(UUID().uuidString)") }
    }
}

func localIPv4() throws -> String {
    // Prefer the default route's interface over VPN, bridge, or inactive adapters.
    let route = Process(); let pipe = Pipe()
    route.executableURL = URL(fileURLWithPath: "/sbin/route"); route.arguments = ["-n", "get", "default"]
    route.standardOutput = pipe; route.standardError = FileHandle.nullDevice
    try route.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    route.waitUntilExit()
    let interface = output.split(separator: "\n").first { $0.contains("interface:") }?.split(separator: " ").last.map(String.init)
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { throw NSError(domain: "Cannot list interfaces", code: 1) }
    defer { freeifaddrs(interfaces) }
    var pointer = interfaces
    while let entry = pointer {
        defer { pointer = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              String(cString: entry.pointee.ifa_name) == interface else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: buffer)
        }
    }
    throw NSError(domain: "No LAN IPv4 found. Pass --device-host with this Mac's LAN address.", code: 1)
}

final class MenuDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let url: URL
    init(url: URL) { self.url = url }
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "AI TRMNL")
        let menu = NSMenu()
        let title = NSMenuItem(title: "AI TRMNL · Local server running", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title); menu.addItem(.separator())
        let help = NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        let copy = NSMenuItem(title: "Copy Agent URL", action: #selector(copyURL), keyEquivalent: "")
        copy.target = self; menu.addItem(copy); menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AI TRMNL", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); item?.menu = menu
    }
    @objc func openHelp() { NSWorkspace.shared.open(url) }
    @objc func copyURL() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

do {
    let options = try LaunchOptions()
    let host = try options.host ?? localIPv4()
    var address = in_addr()
    guard inet_pton(AF_INET, host, &address) == 1, host != "0.0.0.0" else { throw NSError(domain: "Use a reachable numeric IPv4 for --device-host", code: 1) }
    try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lock = open(options.directory.appendingPathComponent("server.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "Another AI TRMNL process is using this data directory", code: 1) }
    let secret = try options.ephemeral ? Data(UUID().uuidString.utf8) : SecretStore.loadOrCreate(for: options.directory)
    let configuration = Configuration(directory: options.directory, deviceHost: host, devicePort: options.devicePort,
                                      agentPort: options.agentPort, refreshSeconds: options.refresh)
    let service = try TRMNLService(configuration: configuration, secret: secret)
    let queue = DispatchQueue(label: "com.brianpattison.ai-trmnl.server")
    let agent = try HTTPServer(host: "127.0.0.1", port: options.agentPort, queue: queue, handler: service.agent)
    let firmware = try HTTPServer(host: host, port: options.devicePort, queue: queue, handler: service.firmware)
    firmware.onRejectedRequest = service.recordRejectedDeviceRequest
    let failure: (String) -> Void = { error in
        fputs("Server failed: \(error)\n", stderr)
        DispatchQueue.main.async {
            if !options.headless {
                let alert = NSAlert(); alert.messageText = "AI TRMNL could not start"; alert.informativeText = error
                alert.runModal()
            }
            exit(1)
        }
    }
    agent.onFailure = failure; firmware.onFailure = failure
    agent.start(); firmware.start()
    print("AI TRMNL 0.1.0\nHelp / agent: \(configuration.agentURL)/\nTRMNL custom server: \(configuration.deviceURL)\nRefresh: \(options.refresh)s\nData: \(options.directory.path)")
    fflush(stdout)
    if options.headless { dispatchMain() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuDelegate(url: URL(string: configuration.agentURL + "/")!)
    app.delegate = delegate
    withExtendedLifetime((agent, firmware, service, delegate)) { app.run() }
    if options.ephemeral { try? FileManager.default.removeItem(at: options.directory) }
} catch {
    fputs("AI TRMNL: \(error)\n", stderr)
    exit(1)
}
