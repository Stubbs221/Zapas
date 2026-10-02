import AppKit
import Observation
import ServiceManagement
import SwiftUI
import ZapasCore

@MainActor @Observable
final class AppModel {
    var frame = DiagnosticFrame()
    var startupIssue: String?
    var chrome: ChromeModel?
    var development: DevelopmentModel?
    private var service: GUIService?
    private var listener: GUIServiceListener?
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
        } else if let index = arguments.firstIndex(of: "--qualification-window-after"), arguments.indices.contains(index + 1),
                  let delay = Double(arguments[index + 1]), (1...600).contains(delay) {
            // Finite opt-in test delay allows a real background measurement before opening the identical view.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.openQualificationWindow()
            }
        }
        if let index = arguments.firstIndex(of: "--demo"), arguments.indices.contains(index + 1),
           ["empty", "error", "unknown", "stale"].contains(arguments[index + 1]) {
            demo = arguments[index + 1]; frame = DiagnosticDemo.frame(arguments[index + 1])
            return
        }
        do {
            let policies = ProcessInfo.processInfo.environment["ZAPAS_EPHEMERAL"] == "1" ? [:] : UserDefaults.standard.dictionary(forKey: "chromeExclusions") as? [String: [String]] ?? [:]
            let service = try GUIService(coordinator: coordinator, policies: policies)
            self.service = service
            development = DevelopmentModel(service: service)
            let chrome = ChromeModel(service: service); self.chrome = chrome
            let listener = try GUIServiceListener { request in await service.handle(request) }
            self.listener = listener; listener.start()
        } catch {
            let code = (error as? ProbeIssue)?.code ?? "ipc_failed"
            startupIssue = "Chrome-интеграция недоступна (\(code)); системная диагностика продолжает работать."
            if code == "service_already_running" {
                startupIssue = "Другой экземпляр Zapas уже работает. Используйте его; второй монитор не запущен."
                return // A second GUI must not start another persistent sampler.
            }
            if let service { chrome = ChromeModel(service: service); chrome?.serviceIssue = "Локальная связь недоступна (\(code))" }
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
            Task { await self.service?.suspend(); await coordinator.willSleep() }
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
        chrome?.visibility(visible)
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
        Task { _ = await coordinator.refresh(includeProcesses: true); await chrome?.refresh(); await development?.refresh() }
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
        chrome?.stop(); listener?.stop(); listener = nil
        qualification?.stop()
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
        Task { await service?.suspend(); await coordinator.stop(); NSApplication.shared.terminate(nil) }
    }
}
