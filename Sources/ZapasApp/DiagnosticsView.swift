import SwiftUI
import ServiceManagement
import ZapasCore

struct DiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var settings = false
    @State private var integrations = false
    @State private var showAll = false
    @State private var expandedApplications: Set<String> = []
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let now = Date()
        VStack(spacing: 0) {
            header(at: now)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let demo = model.demo {
                        Text("ДЕМО: \(demo). Синтетические данные")
                            .font(.caption.bold()).foregroundStyle(.orange)
                        Picker("Состояние демо", selection: Binding(get: { model.demo ?? "empty" }, set: model.selectDemo)) {
                            Text("Пусто").tag("empty")
                            Text("Ошибка").tag("error")
                            Text("Неизвестно").tag("unknown")
                            Text("Устарело").tag("stale")
                        }
                        Toggle("Тёмная тема демо", isOn: Binding(get: { model.demoDark }, set: model.setDemoDark))
                        Toggle("Усиленный контраст демо", isOn: $model.demoContrast)
                    }
                    systemCard(at: now)
                    historyCard(at: now)
                    applicationsCard(at: now)
                    DisclosureGroup("Интеграции — отложены", isExpanded: $integrations) {
                        Text("Chrome: вкладки появятся в этапе C; точная RAM вкладок неизвестна.\nСимуляторы и LLDB: этап D, активность отладки неизвестна.\nCharles: сохранение сессий не квалифицировано.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }.card()
                    if settings { settingsCard }
                }.padding(14)
            }
            Divider()
            HStack {
                Text("Zapas · Только диагностика").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Настройки").accessibilityLabel("Настройки").keyboardShortcut(",")
                Button("Выход") { model.quit() }.keyboardShortcut("q")
            }.padding(12)
        }
        .frame(width: 420, height: model.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowVisibility(changed: model.visibility).frame(width: 0, height: 0))
    }
    private func header(at now: Date) -> some View {
        HStack(alignment: .center) {
            Image(systemName: "memorychip").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Zapas").font(.headline)
                Text("Давление: \(model.pressureText)").font(.caption)
                    .foregroundStyle(Color(nsColor: model.pressureColor))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Обновить диагностику").help("Обновить").keyboardShortcut("r")
                if let at = model.frame.system?.measuredAt {
                    Text(at, style: .time).font(.caption2).foregroundStyle(.secondary)
                } else { Text("Нет замера").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(14)
    }
    private func systemCard(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Система").font(.headline)
            if model.frame.sleeping { notice("Сбор приостановлен: сон") }
            TimelineView(VisibleClock(active: model.windowVisible)) { _ in
                if model.frame.systemStale(at: Date()) { notice("Устаревший замер — ожидается обновление") }
            }
            if let error = model.frame.systemError { issue(error) }
            if let s = model.frame.system {
                metricRow("Физическая RAM", s.physical)
                metricRow("Wired", s.wired)
                metricRow("Компрессор", s.compressed)
                metricRow("Swap занят / всего", s.swapUsed, second: s.swapTotal)
                metricRow("Swap чтение", s.swapReadRate)
                metricRow("Swap запись", s.swapWriteRate)
                if let error = s.pressure.error { issue(error, message: "Событие давления ещё не наблюдалось. Занятость RAM не определяет давление.") }
            } else if model.frame.systemError == nil {
                Text(model.demo == "empty" ? "Системных данных пока нет" : "Получаем системные показатели…").foregroundStyle(.secondary)
            }
        }.card()
    }
    private func historyCard(at now: Date) -> some View {
        let points = HistoryChart.points(model.frame.history)
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Последние 15 минут").font(.headline); Spacer(); Text("GiB").font(.caption).foregroundStyle(.secondary) }
            if points.isEmpty {
                Text("История появится после доступных замеров").font(.caption).foregroundStyle(.secondary).frame(height: 80)
            } else {
                MemoryHistoryChart(points: points, now: now, highContrast: contrast == .increased || model.demoContrast)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("График swap и компрессора за последние 15 минут, GiB")
                .accessibilityValue(chartSummary)
            }
            Text(chartSummary).font(.caption2).foregroundStyle(.secondary)
            Text("Пропуски и неизвестные значения не соединяются.").font(.caption2).foregroundStyle(.secondary)
        }.card()
    }
    private var chartSummary: String {
        guard let s = model.frame.system else { return "Нет доступных значений" }
        return "Последний замер: swap \(formatted(s.swapUsed)), компрессор \(formatted(s.compressed))."
    }
    private func applicationsCard(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("Приложения").font(.headline); Spacer(); Text("Footprint").font(.caption).foregroundStyle(.secondary) }
            if let processes = model.frame.processes {
                TimelineView(VisibleClock(active: model.windowVisible)) { _ in
                HStack(spacing: 4) {
                    if model.frame.processesStale(at: Date()) {
                        Image(systemName: "exclamationmark.circle")
                        Text("Список устарел — ожидается обновление")
                    } else {
                        Text("Обновлён")
                        Text(processes.measuredAt, style: .time)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(model.frame.processesStale(at: Date()) ? Color.orange : Color.secondary)
                .frame(height: 18)
                }
            }
            if let error = model.frame.processError { issue(error) }
            if let p = model.frame.processes {
                if p.processes.isEmpty { Text("Наблюдаемых процессов нет").font(.caption).foregroundStyle(.secondary) }
                if !p.failures.isEmpty {
                    Text("Не удалось прочитать \(p.failures.count) процессов; принадлежность этих ошибок неизвестна.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(showAll ? model.frame.applications : Array(model.frame.applications.prefix(12))) { app in
                        DisclosureGroup(isExpanded: Binding(get: { expandedApplications.contains(app.id) }, set: { expanded in
                            if expanded { expandedApplications.insert(app.id) } else { expandedApplications.remove(app.id) }
                        })) {
                            // Collapsed groups do not allocate hundreds of hidden process rows.
                            if expandedApplications.contains(app.id) {
                                Text("\(app.measuredCount) прочитано, \(app.unavailableCount) недоступно").font(.caption2).foregroundStyle(.secondary)
                                ForEach(app.processes) { process in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(process.name) · PID \(process.identity.pid)").font(.caption)
                                        metricRow("Footprint", process.footprint)
                                        metricRow("RSS отдельно", process.rss)
                                    }.padding(.vertical, 4)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: app.bundlePath == nil ? "gearshape" : "app")
                                Text(app.name).lineLimit(1).help(app.name)
                                Spacer()
                                Text(formatted(app.footprint)).monospacedDigit().font(.caption)
                            }
                        }.font(.subheadline)
                    }
                }
                if model.frame.applications.count > 12 {
                    Button(showAll ? "Показать первые 12" : "Показать все (\(model.frame.applications.count))") { showAll.toggle() }.font(.caption)
                }
                Text("Сумма наблюдаемого footprint — частичный учёт процессов, не уникальная физическая RAM и не RAM вкладок. RSS к ней не прибавляется.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if model.frame.processError == nil { Text("Получаем список процессов…").font(.caption).foregroundStyle(.secondary) }
        }.card()
    }
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Настройки").font(.headline)
            Toggle("Подпись состояния в строке меню", isOn: $model.showStatus)
            Toggle("Запускать при входе", isOn: Binding(get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval }, set: model.setLogin))
                .disabled(model.loginBusy || model.demo != nil)
            if model.loginStatus == .requiresApproval { notice("Требуется разрешение в системных настройках входа") }
            if model.loginStatus == .notFound { notice("Система не нашла подписанное приложение для запуска при входе") }
            if let error = model.loginError { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("История хранится только в памяти: до 15 минут / 600 точек. Сбор: 3 с в окне, 30 с в фоне. Данные не отправляются наружу.")
                .font(.caption2).foregroundStyle(.secondary)
        }.font(.subheadline).card()
    }
    private func metricRow(_ name: String, _ metric: DiagnosticMetric, second: DiagnosticMetric? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption)
                Spacer()
                Text(formatted(metric) + (second.map { " / " + formatted($0) } ?? "")).font(.caption).monospacedDigit()
            }.accessibilityElement(children: .combine)
            if let error = metric.error { issue(error) }
            if let error = second?.error { issue(error) }
        }.help("Источник: \(metric.source)")
    }
    private func issue(_ error: ProbeIssue, message: String? = nil) -> some View {
        Text(message ?? localized(error)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            .help("\(error.code): \(error.message)")
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
    }
    private func localized(_ error: ProbeIssue) -> String {
        switch error.code {
        case "first_sample": "Нужны два сопоставимых замера"
        case "no_pressure_event": "Событие давления ещё не наблюдалось"
        case "sampling_gap", "counter_reset", "boot_changed", "page_size_changed": "Интервал несопоставим: ожидается новый замер"
        case "swap_api", "vm_api", "system_api", "system_failed", "counter_unavailable": "Системный показатель недоступен (\(error.code))"
        case "application_memory_unavailable", "process_memory_unavailable": "Память процесса недоступна"
        default: "Данные недоступны (\(error.code))"
        }
    }
    private func formatted(_ metric: DiagnosticMetric) -> String {
        guard let value = metric.value else { return "Неизвестно" }
        let divisor: Double = metric.unit == "bytes/second" ? 1_048_576 : 1_073_741_824
        let suffix = metric.unit == "bytes/second" ? "MiB/с" : "GiB"
        return (value / divisor).formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "ru_RU"))) + " " + suffix
    }
}

/// A timer rather than a display link; a hidden window gets no recurring UI clock.
private struct VisibleClock: TimelineSchedule {
    let active: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if active {
            return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 1).entries(from: startDate, mode: mode))
        }
        return AnySequence([startDate])
    }
}

/// A bounded 2-series chart without the large Charts runtime and per-point symbol allocations.
private struct MemoryHistoryChart: View {
    let points: [ChartPoint]
    let now: Date
    let highContrast: Bool
    var body: some View {
        let maximum = max(1, ceil((points.map(\.valueGiB).max() ?? 0) / 3) * 3)
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack { Text(maximum.formatted(.number.precision(.fractionLength(0)))); Spacer(); Text("0") }
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 20)
                NativeHistoryPlot(points: points, maximum: maximum, now: now, highContrast: highContrast).clipped()
            }.frame(height: 80)
            HStack { Text("−15 мин"); Spacer(); Text("−10"); Spacer(); Text("−5"); Spacer(); Text("Сейчас") }
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("Swap · пунктир", systemImage: "minus").foregroundStyle(.orange)
                Label("Компрессор", systemImage: "minus").foregroundStyle(.blue)
            }.font(.caption2)
        }
    }
}

private struct NativeHistoryPlot: NSViewRepresentable {
    let points: [ChartPoint]
    let maximum: Double
    let now: Date
    let highContrast: Bool
    func makeNSView(context: Context) -> HistoryPlotView { HistoryPlotView() }
    func updateNSView(_ view: HistoryPlotView, context: Context) {
        view.groups = Dictionary(grouping: points, by: \.segment)
        view.maximum = maximum; view.now = now; view.highContrast = highContrast
        view.needsDisplay = true
    }
}

@MainActor private final class HistoryPlotView: NSView {
    var groups: [String: [ChartPoint]] = [:]
    var maximum = 1.0
    var now = Date()
    var highContrast = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.4 : 0.15).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        for index in 0...3 {
            let y = bounds.height * Double(index) / 3
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: y))
            let x = bounds.width * Double(index) / 3
            grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: bounds.height))
        }
        grid.stroke()
        for group in groups.values {
            let swap = group.first?.kind == "Swap"
            let color = swap ? NSColor.systemOrange : NSColor.systemBlue
            color.setStroke(); color.setFill()
            let path = NSBezierPath(); path.lineWidth = highContrast ? 3 : 2
            if swap { path.setLineDash([4, 3], count: 2, phase: 0) }
            for (index, point) in group.enumerated() {
                let x = min(1, max(0, point.measuredAt.timeIntervalSince(now.addingTimeInterval(-900)) / 900)) * bounds.width
                let y = min(bounds.height - 1, max(1, (1 - point.valueGiB / maximum) * bounds.height))
                if index == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
                if group.count == 1 { NSBezierPath(ovalIn: NSRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill() }
            }
            path.stroke()
        }
    }
}

private extension View {
    func card() -> some View {
        padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
