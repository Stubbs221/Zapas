import AppKit
import Observation
import ZapasCore

@MainActor @Observable
final class ChromeModel {
    var profiles: [ChromeProfile] = []
    var selected: Set<ChromeSelection> = []
    var plan: ChromePlan?
    var batch: ChromeBatch?
    var issue: String?
    var installation: String?
    var busy = false
    var serviceIssue: String?
    private let service: GUIService
    private var polling: Task<Void, Never>?
    private var execution: Task<Void, Never>?
    private var exclusions: [String: [String]] = UserDefaults.standard.dictionary(forKey: "chromeExclusions") as? [String: [String]] ?? [:]
    init(service: GUIService) {
        self.service = service

    }
    func visibility(_ visible: Bool) {
        polling?.cancel(); polling = nil
        if visible {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }
    func refresh() async {
        profiles = await service.profiles()
        let live = Set(profiles.filter { !$0.stale }.flatMap { profile in profile.tabs.filter { profile.policy.exclusion($0, kind: .close, now: Date()) == nil }.map { selection(profile, $0) } })
        selected.formIntersection(live)
        if let plan, Set(plan.targets.map(\.selection)) != selected { self.plan = nil }
    }
    func selection(_ profile: ChromeProfile, _ tab: ChromeTab) -> ChromeSelection {
        ChromeSelection(profileID: profile.id, sessionID: profile.sessionID, tabID: tab.id, token: tab.token)
    }
    func select(_ value: ChromeSelection, _ enabled: Bool) {
        guard !busy else { return }
        plan = nil
        if enabled { selected.insert(value) } else { selected.remove(value) }
    }
    func clearSelection() { guard !busy else { return }; selected.removeAll(); plan = nil }
    func preview(_ kind: ChromeActionKind) {
        guard !busy else { return }
        issue = nil; plan = nil; batch = nil; busy = true
        let choices = Array(selected)
        Task {
            defer { busy = false }
            var request = ServiceRequest("tabsPreview"); request.kind = kind; request.selections = choices
            let reply = await service.handle(request)
            if let error = reply.issue { issue = explanation(error.code, detail: error.message) }
            else { plan = reply.plan }
        }
    }
    func cancelPreview() { plan = nil }
    func apply() {
        guard let plan, !busy else { return }
        self.plan = nil; busy = true; issue = nil
        execution = Task {
            defer { busy = false; execution = nil }
            var request = ServiceRequest("tabsApply"); request.planID = plan.id
            var reply = await service.handle(request)
            if let error = reply.issue { issue = explanation(error.code, detail: error.message); return }
            batch = reply.batch; selected.removeAll()
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                request = ServiceRequest("tabsResult"); request.planID = plan.id
                reply = await service.handle(request); batch = reply.batch
                if batch?.results.allSatisfy({ $0.issue != "awaiting_confirmation" }) == true { break }
            }
            await refresh()
        }
    }
    func exclude(_ domain: String, profile: ChromeProfile, enabled: Bool) {
        plan = nil
        var domains = profile.policy.excludedDomains
        if enabled { if !domains.contains(domain) { domains.append(domain) } }
        else { domains.removeAll { $0 == domain } }
        exclusions[profile.id] = domains
        if ProcessInfo.processInfo.environment["ZAPAS_EPHEMERAL"] != "1" { UserDefaults.standard.set(exclusions, forKey: "chromeExclusions") }
        Task { do { try await service.setPolicy(ChromePolicy(excludedDomains: domains), profileID: profile.id); await refresh() } catch { issue = "Не удалось изменить исключения" } }
    }
    func install() {
        let panel = NSOpenPanel(); panel.title = "Выберите каталог Chrome user-data для Native Messaging"
        panel.message = "Будет создан только NativeMessagingHosts/com.zapas.chrome.json. Расширение загружается отдельно. Для проверки выберите изолированный профиль в .local/."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zapas-native-host")
            let result = try NativeInstallation.install(hostExecutable: host, userDataDirectory: directory)
            installation = "Native Messaging установлен: \(result.deletingLastPathComponent().lastPathComponent). Загрузите расширение и нажмите Подключить."
            issue = nil
        } catch { issue = "Установка не выполнена: \((error as? ProbeIssue)?.code ?? "install_failed")" }
    }
    func showExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/chrome-extension")])
    }
    func stop() { polling?.cancel(); execution?.cancel() }
    func reason(_ code: String) -> String {
        switch code {
        case "active": "Активная в своём окне"
        case "pinned": "Закреплена"
        case "audible": "Воспроизводит звук"
        case "incognito": "Инкогнито"
        case "recently_active": "Активность менее 10 минут назад"
        case "activity_unknown": "Активность неизвестна"
        case "user_excluded": "Домен в исключениях"
        case "already_discarded": "Уже выгружена"
        case "navigation_pending": "Переход страницы"
        case "domain_unknown": "Домен неизвестен"
        case "split_view": "Разделённый вид"
        default: code
        }
    }
    private func explanation(_ code: String, detail: String) -> String {
        if code == "tab_excluded" { return "Действие запрещено: " + reason(detail) }
        return "Выбор изменился или устарел (\(code)). Обновите список и создайте новый preview."
    }
}
