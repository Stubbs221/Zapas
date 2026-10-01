import AppKit
import Observation
import ServiceManagement
import SwiftUI
import ZapasCore

@MainActor @Observable
final class AppModel {
    var frame = DiagnosticFrame()
    var showStatus = UserDefaults.standard.object(forKey: "showStatus") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showStatus, forKey: "showStatus") }
    }
    var loginStatus = SMAppService.mainApp.status
    var loginError: String?
    var loginBusy = false
    var demo: String?
    var demoDark = false
    var demoContrast = false
    var windowVisible = false
    var windowHeight: CGFloat { min(660, max(1, (NSScreen.main?.visibleFrame.height ?? 700) - 40)) }
    private let coordinator = SamplingCoordinator()
    private var updates: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var qualification: QualificationRecorder?
    private var qualificationWindow: NSWindow?
    private var visibleWindows: Set<ObjectIdentifier> = []

    init() {
        let arguments = CommandLine.arguments
        qualification = QualificationRecorder(arguments: arguments)
        if arguments.contains("--qualification-window") {
            // A developer-only native window hosts the identical view; normal launch has only MenuBarExtra.
            Task { [weak self] in self?.openQualificationWindow() }
        }
        if let index = arguments.firstIndex(of: "--demo"), arguments.indices.contains(index + 1),
           ["empty", "error", "unknown", "stale"].contains(arguments[index + 1]) {
            demo = arguments[index + 1]; frame = DiagnosticDemo.frame(arguments[index + 1])
            return
        }
        let coordinator = coordinator
        updates = Task { [weak self] in
            let stream = await coordinator.updates()
            await coordinator.start()
            for await frame in stream {
                guard !Task.isCancelled else { break }
                self?.frame = frame
                self?.qualification?.sample(frame)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await coordinator.willSleep() }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await coordinator.didWake() }
        })
    }
    func visibility(_ id: ObjectIdentifier, _ windowIsVisible: Bool) {
        if windowIsVisible { visibleWindows.insert(id) } else { visibleWindows.remove(id) }
        let visible = !visibleWindows.isEmpty
        guard windowVisible != visible else { return }
        windowVisible = visible
        qualification?.visibility(visible)
        loginStatus = SMAppService.mainApp.status
        guard demo == nil else { return }
        Task { await coordinator.setDetailed(visible) }
    }
    private func openQualificationWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: windowHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Zapas — проверка интерфейса"
        window.contentView = NSHostingView(rootView: DiagnosticsView(model: self))
        window.isReleasedWhenClosed = false
        qualificationWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func refresh() {
        if let demo { frame = DiagnosticDemo.frame(demo); return }
        Task { _ = await coordinator.refresh(includeProcesses: true) }
    }
    func selectDemo(_ mode: String) {
        guard demo != nil, ["empty", "error", "unknown", "stale"].contains(mode) else { return }
        demo = mode; frame = DiagnosticDemo.frame(mode)
    }
    func setDemoDark(_ dark: Bool) {
        guard demo != nil else { return }
        demoDark = dark
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
    var pressureText: String {
        switch frame.system?.pressure.state {
        case "normal": "Нормальное"
        case "warning": "Повышенное"
        case "critical": "Критическое"
        default: "Неизвестно"
        }
    }
    var pressureColor: NSColor {
        switch frame.system?.pressure.state {
        case "normal": .systemGreen
        case "warning": .systemOrange
        case "critical": .systemRed
        default: .secondaryLabelColor
        }
    }
    func setLogin(_ enabled: Bool) {
        guard !loginBusy else { return }
        loginBusy = true; loginError = nil
        Task {
            defer { loginBusy = false; loginStatus = SMAppService.mainApp.status }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { loginError = "Не удалось изменить запуск при входе: \(error.localizedDescription)" }
        }
    }
    func quit() {
        updates?.cancel()
        qualification?.stop()
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
        Task { await coordinator.stop(); NSApplication.shared.terminate(nil) }
    }
}
