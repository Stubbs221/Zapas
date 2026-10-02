import AppKit
import Observation
import ZapasCore

@MainActor @Observable
final class DevelopmentModel {
    var simulators: SimulatorDiagnostics?
    var debuggers: DebuggerDiagnostics?
    var selected: AssignedSimulator?
    var selectedDebugger: ProcessIdentity?
    var plan: DActionPlan?
    var outcome: DActionOutcome?
    var simulatorIssue: String?
    var debuggerIssue: String?
    var issue: String?
    var busy = false
    private let service: GUIService
    init(service: GUIService) { self.service = service }
    func refresh() async {
        guard !busy else { return }
        busy = true; plan = nil; selected = nil; selectedDebugger = nil
        defer { busy = false }
        let devices = await service.handle(ServiceRequest("simulatorsList"))
        simulators = devices.simulators; simulatorIssue = devices.issue.map { "Список недоступен: \($0.code)" }
        let debug = await service.handle(ServiceRequest("debuggersList"))
        debuggers = debug.debuggers; debuggerIssue = debug.issue.map { "Список недоступен: \($0.code)" }
    }
    func select(_ device: AssignedSimulator) { guard !busy else { return }; selected = device; selectedDebugger = nil; plan = nil; outcome = nil; issue = nil }
    func selectDebugger(_ identity: ProcessIdentity) { guard !busy else { return }; selectedDebugger = identity; selected = nil; plan = nil; outcome = nil; issue = nil }
    func preview() {
        guard !busy, selected != nil || selectedDebugger != nil else { return }
        busy = true; issue = nil; outcome = nil
        var request = ServiceRequest(selected != nil ? "simulatorsPreview" : "debuggersPreview")
        request.simulator = selected; request.debuggerIdentity = selectedDebugger
        Task {
            defer { busy = false }
            let reply = await service.handle(request)
            plan = reply.developmentPlan; issue = reply.issue.map { "Preview не создан: \($0.code)" }
        }
    }
    func cancel() { plan = nil }
    func apply() {
        guard let plan, !busy else { return }
        self.plan = nil; busy = true; issue = nil
        Task {
            var request = ServiceRequest("developmentApply"); request.planID = plan.id; request.apply = true; request.developmentKind = plan.kind
            let reply = await service.handle(request)
            outcome = reply.developmentOutcome; issue = reply.issue.map { "Действие не выполнено: \($0.code)" }
            selected = nil; selectedDebugger = nil; busy = false
            await refresh()
        }
    }
    func assignment() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Назначение Simulator для Zapas"
        panel.message = "Выберите .local/simulator-assignment.json с runtime, dataPath и incarnation. Имя устройства и Booted не определяют принадлежность."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await service.setSimulatorAssignment(url.path)
                if ProcessInfo.processInfo.environment["ZAPAS_EPHEMERAL"] != "1" { UserDefaults.standard.set(url.path, forKey: "simulatorAssignmentPath") }
                await refresh()
            } catch { issue = "Назначение не принято: \((error as? ProbeIssue)?.code ?? "assignment_failed")" }
        }
    }
}
