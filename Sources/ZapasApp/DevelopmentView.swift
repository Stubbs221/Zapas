import SwiftUI
import ZapasCore

struct DevelopmentView: View {
    @Bindable var model: DevelopmentModel
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Simulator и LLDB", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Обновить список") { Task { await model.refresh() } }.disabled(model.busy)
                    Spacer()
                    Button("Назначение…") { model.assignment() }.disabled(model.busy)
                }
                Text("Ручной выбор одного назначенного Zapas iOS-устройства. Список обновляется по запросу.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.busy { ProgressView("Проверяем выбранный объект…").controlSize(.small) }
                if let issue = model.simulatorIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if let list = model.simulators {
                    Text("Simulator · всего \(list.totalDeviceCount)").font(.subheadline.bold())
                    Text(list.measuredAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    if let issue = list.assignmentIssue { Text("Назначение недоступно: \(issue.code)").font(.caption).foregroundStyle(.orange) }
                    if list.devices.isEmpty { Text("Устройств нет").font(.caption) }
                    ForEach(list.devices) { entry in
                        DisclosureGroup {
                            Text(entry.device.udid).font(.caption2.monospaced()).textSelection(.enabled)
                            Text(entry.device.runtime).font(.caption2).textSelection(.enabled)
                            Text("Принадлежность: \(entry.device.assignment == "unknown_or_other_project" ? "неизвестна" : entry.device.assignment). \(entry.assignmentVerified ? "Назначение проверено" : "Identity назначения не подтверждена")")
                                .font(.caption2).foregroundStyle(.secondary)
                            let processes = list.processes.first { $0.udid == entry.id }?.processes ?? []
                            if processes.isEmpty { Text("Процессы по dataPath не наблюдались; это не доказательство отсутствия приложений/отладки.").font(.caption2).foregroundStyle(.secondary) }
                            ForEach(processes) { process in processRow(process) }
                            Button(model.selected == entry ? "Выбрано" : "Выбрать это устройство") { model.select(entry) }
                                .disabled(!entry.canSelect || model.busy)
                                .accessibilityLabel("Выбрать устройство \(entry.device.name), \(entry.device.udid)")
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.device.name).font(.subheadline).lineLimit(2)
                                Text("\(entry.device.isIOS ? "iOS" : "Другой runtime") · \(entry.device.state) · \(entry.device.isAvailable ? "Доступно" : "Недоступно")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let issue = list.processIssue { Text("Процессы недоступны: \(issue.code)").font(.caption).foregroundStyle(.orange) }
                    if !list.processFailures.isEmpty { Text("Не прочитано процессов: \(list.processFailures.count); принадлежность ошибок неизвестна.").font(.caption2).foregroundStyle(.secondary) }
                    DisclosureGroup("Helpers с неизвестным устройством (\(list.unassignedProcesses.count))") {
                        ForEach(list.unassignedProcesses) { process in processRow(process) }
                    }.font(.caption)
                }
                Divider()
                Text("LLDB · только доказательства").font(.subheadline.bold())
                Text("Живая Run / breakpoint / Stop квалификация отложена. Неизвестная активность блокирует завершение.")
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = model.debuggerIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if let list = model.debuggers {
                    if list.debuggers.isEmpty { Text("LLDB не наблюдался").font(.caption).foregroundStyle(.secondary) }
                    ForEach(list.debuggers) { debugger in
                        DisclosureGroup("\(debugger.process.name) · PID \(debugger.id.pid)") {
                            processRow(debugger.process)
                            Text("Активность: \(activity(debugger.activity)) · Сиротство: \(orphanhood(debugger.orphanhood))").font(.caption)
                            ForEach(Array(debugger.evidence.enumerated()), id: \.offset) { _, evidence in
                                Text("\(evidence.code): \(evidence.explanation)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Button("Выбрать доказанно осиротевший LLDB") { model.selectDebugger(debugger.id) }
                                .disabled(!debugger.canTerminate || model.busy)
                        }.font(.caption)
                    }
                }
                if let selected = model.selected { Text("Выбрано: \(selected.device.name)").font(.caption.bold()) }
                if model.selected != nil || model.selectedDebugger != nil {
                    Button("Проверить воздействие…") { model.preview() }.disabled(model.busy)
                }
                if let issue = model.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if let outcome = model.outcome {
                    Text("Результат: \(outcome.result.status.rawValue)").font(.subheadline.bold())
                    if let issue = outcome.result.issue { Text(resultDescription(issue)).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Footprint и RSS — отдельно. Принадлежность определяется только конкретным dataPath; общий helper не приписывается устройству.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .onChange(of: expanded) { _, value in if value && model.simulators == nil { Task { await model.refresh() } } }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.cancel() } })) {
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Проверка воздействия").font(.headline)
                    if let device = plan.simulator {
                        Text(device.device.name).font(.subheadline.bold())
                        Text("\(device.device.runtime)\n\(device.id)\n\(device.device.state)").font(.caption).textSelection(.enabled)
                    }
                    Text(plan.impact).font(.subheadline)
                    Text("Наблюдаемых процессов: \(plan.affectedProcesses.count). Список частичный.").font(.caption)
                    if let issue = plan.impactIssue { Text(issue.message).font(.caption).foregroundStyle(.secondary) }
                    Text("План действует 30 секунд; identity, runtime, назначение и состояние проверяются повторно.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Отмена") { model.cancel() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(plan.simulator?.device.state == "Shutdown" ? "Подтвердить уже Shutdown" : plan.kind == .simulatorShutdown ? "Выключить это устройство" : "Завершить этот LLDB", role: .destructive) { model.apply() }
                            .disabled(model.busy || plan.expiresAt <= Date())
                    }
                }.padding(20).frame(width: 380)
            }
        }
    }
    private func activity(_ value: DebugActivity) -> String {
        switch value { case .active: "активна"; case .inactive: "неактивна"; case .unknown: "неизвестна" }
    }
    private func orphanhood(_ value: DebugOrphanhood) -> String {
        switch value { case .proven: "доказано"; case .candidate: "только кандидат"; case .unknown: "неизвестно" }
    }
    private func resultDescription(_ issue: ProbeIssue) -> String {
        switch issue.code {
        case "device_already_shutdown": "Устройство уже выключено. Команда не отправлялась."
        case "device_still_booted": "Устройство осталось Booted."
        case "device_disappeared", "device_identity_or_assignment_changed": "После действия устройство или назначение изменилось. Результат неизвестен."
        case "device_not_authorized", "device_identity_or_state_changed": "Выбор изменился. Создайте новый preview."
        default: "Проверка результата: \(issue.code). Неизвестный результат не означает успех."
        }
    }
    private func processRow(_ process: DiagnosticProcess) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(process.name) · PID \(process.identity.pid)").font(.caption)
            Text("Footprint: \(memory(process.footprint)) · RSS: \(memory(process.rss))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
    private func memory(_ metric: DiagnosticMetric) -> String {
        guard let value = metric.value else { return "неизвестно (\(metric.error?.code ?? "unavailable"))" }
        return String(format: "%.1f MiB", value / 1_048_576)
    }
}
