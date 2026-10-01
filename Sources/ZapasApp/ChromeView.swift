import SwiftUI
import ZapasCore

struct ChromeView: View {
    @Bindable var model: ChromeModel
    @State private var opened: Set<String> = []
    @State private var query = ""
    @State private var filter: ChromeTabFilter = .all
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "globe").font(.title2).foregroundStyle(.blue)
                    .frame(width: 36, height: 36).background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chrome").font(.headline)
                    Text("RAM вкладок неизвестна").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                badge(model.profiles.contains { !$0.stale } ? "Подключён" : "Нет связи", symbol: "circle.fill", color: model.profiles.contains { !$0.stale } ? .green : .secondary)
            }
            DisclosureGroup("Подключение и защита") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Выберите корень Chrome user-data, загрузите расширение в Chrome и нажмите «Подключить» в расширении.")
                    HStack {
                        Button("Установить Native Messaging") { model.install() }
                        Button("Папка расширения") { model.showExtension() }
                    }
                    Text("Защищены active, pinned, audible, incognito, неизвестная активность и последние 10 минут. Исключения задаются для каждого профиля. Звонки и формы нельзя надёжно обнаружить.")
                    Text("Сортировка — по давности активности внутри окна. Footprint всей группы Chrome находится в приложениях; RSS отдельно. Сумма не является уникальной RAM.")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.caption)
            if let issue = model.serviceIssue { notice(issue) }
            if let installation = model.installation { notice(installation) }
            if let issue = model.issue { notice(issue) }
            if model.profiles.isEmpty {
                Label("Подключите профиль Chrome", systemImage: "link").font(.subheadline.weight(.medium))
                Text("Расширение отсутствует или отключено. Системная диагностика доступна.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    TextField("Название или домен", text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Поиск вкладок по названию или домену")
                    if !query.isEmpty { Button("Очистить поиск", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).buttonStyle(.plain) }
                    Picker("Фильтр вкладок", selection: $filter) {
                        ForEach(ChromeTabFilter.allCases, id: \.self) { value in Text(filterName(value)).tag(value) }
                    }.labelsHidden().fixedSize().accessibilityLabel("Фильтр вкладок")
                }.font(.caption)
                ForEach(model.profiles) { profile in profileView(profile) }
                selectionBar
            }
            if let plan = model.plan { preview(plan) }
            if model.busy { Label("Проверяем ответ Chrome…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
            if let batch = model.batch { results(batch) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.08), lineWidth: 1))
    }
    private func profileView(_ profile: ChromeProfile) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { opened.contains(profile.id) }, set: {
            if $0 { opened.insert(profile.id) } else { opened.remove(profile.id) }
        })) {
            if opened.contains(profile.id) {
                let tabs = visibleTabs(profile)
                HStack {
                    Text("Показано \(tabs.count) из \(profile.tabs.count)").monospacedDigit()
                    Spacer()
                    badge(profile.stale ? "Устарел" : "Свежий снимок", symbol: profile.stale ? "exclamationmark.circle" : "checkmark.circle", color: profile.stale ? .orange : .secondary)
                }.font(.caption2).padding(.top, 6)
                DisclosureGroup("Исключения доменов · \(profile.policy.excludedDomains.count)") {
                    ForEach(profile.policy.excludedDomains, id: \.self) { domain in
                        HStack {
                            Text(domain); Spacer()
                            Button("Убрать") { model.exclude(domain, profile: profile, enabled: false) }.disabled(model.busy)
                        }
                    }
                }.font(.caption).padding(.vertical, 4)
                if tabs.isEmpty { Text("Нет вкладок для этого фильтра").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                ForEach(Array(Set(tabs.map(\.windowID))).sorted(), id: \.self) { window in
                    HStack {
                        Label("Окно \(window)", systemImage: "macwindow")
                        Spacer()
                        Text("\(tabs.filter { $0.windowID == window }.count)").monospacedDigit()
                    }.font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(tabs.filter { $0.windowID == window }) { tab in row(tab, profile: profile) }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Вкладок: \(profile.tabs.count) · окон: \(Set(profile.tabs.map(\.windowID)).count) · \(profile.id.prefix(8))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func row(_ tab: ChromeTab, profile: ChromeProfile) -> some View {
        let selection = model.selection(profile, tab)
        let reason = profile.stale ? "Снимок устарел" : profile.policy.exclusion(tab, kind: .close, now: Date()).map(model.reason)
        let title = tab.title.isEmpty ? "Без названия" : tab.title
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { model.selected.contains(selection) }, set: { model.select(selection, $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(reason != nil || model.busy)
                .accessibilityLabel("Выбрать вкладку: \(title)").accessibilityHint(reason ?? "Добавить в ручной выбор")
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(tab.domain ?? "Домен неизвестен").lineLimit(1)
                    Text("·")
                    Text(tab.activityAgeMinutes(now: Date()).map { $0.rounded(.down).formatted(.number.precision(.fractionLength(0))) + " мин" } ?? "Активность неизвестна").monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary)
                if let reason { badge(reason, symbol: "lock.fill", color: .secondary) }
                else if tab.discarded { badge("Выгружена", symbol: "moon", color: .secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let domain = tab.domain, !profile.policy.excludedDomains.contains(domain) {
                Menu {
                    Button("Исключить домен \(domain)") { model.exclude(domain, profile: profile, enabled: true) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                .accessibilityLabel("Действия вкладки: \(title)")
                .help("Действия вкладки: \(title)")
            }
        }
        .padding(8).background(model.selected.contains(selection) ? Color.blue.opacity(0.1) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selected.contains(selection) ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1))
    }
    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Label("Выбрано: \(model.selected.count)", systemImage: "checkmark.circle").font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer()
                Button("Снять выбор") { model.clearSelection() }.buttonStyle(.plain).font(.caption).disabled(model.selected.isEmpty || model.busy)
            }
            let visible = Set(model.profiles.flatMap { profile in visibleTabs(profile).map { model.selection(profile, $0) } })
            let hidden = model.selected.subtracting(visible).count
            if hidden > 0 { notice("Скрыто фильтром выбранных вкладок: \(hidden). Они также войдут в preview.") }
            HStack(spacing: 8) {
                Button { model.preview(.discard) } label: { Label("Выгрузить…", systemImage: "moon").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.blue)
                Button(role: .destructive) { model.preview(.close) } label: { Label("Закрыть…", systemImage: "xmark").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            }.controlSize(.regular).disabled(model.selected.isEmpty || model.busy)
            Text("Сначала проверка списка, затем подтверждение. Фильтр не меняет выбор.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func preview(_ plan: ChromePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.kind == .discard ? "Проверка выгрузки · \(plan.targets.count)" : "Проверка закрытия · \(plan.targets.count)", systemImage: "checklist").font(.subheadline.bold())
            ForEach(Array(plan.targets.enumerated()), id: \.offset) { _, target in
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.expected.title).font(.caption.weight(.medium)).lineLimit(2)
                    Text("\(target.expected.domain ?? "?") · окно \(target.expected.windowID)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            notice("Могут быть потеряны формы и состояние страницы. Звонки нельзя надёжно обнаружить. Preview действует 30 секунд; перед действием состояние проверяется снова.")
            if Date() >= plan.expiresAt { notice("План истёк — создайте новый preview") }
            HStack {
                Button(plan.kind == .discard ? "Подтвердить выгрузку" : "Подтвердить закрытие", role: plan.kind == .close ? .destructive : nil) { model.apply() }
                    .disabled(model.busy || Date() >= plan.expiresAt)
                Button("Отмена") { model.cancelPreview() }.disabled(model.busy)
            }.font(.caption)
        }.padding(10).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private func results(_ batch: ChromeBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Результат \(batch.plan.kind == .discard ? "выгрузки" : "закрытия")").font(.subheadline.bold())
            ForEach(Array(batch.results.enumerated()), id: \.element.id) { index, result in
                let status = result.status == "confirmed" ? "Подтверждено" : result.status == "failed" ? "Отказ" : "Неизвестно"
                VStack(alignment: .leading, spacing: 3) {
                    Text(batch.plan.targets[index].expected.title).font(.caption.weight(.medium)).lineLimit(2)
                    badge(status, symbol: result.status == "confirmed" ? "checkmark.circle" : "exclamationmark.circle", color: result.status == "confirmed" ? .green : .orange)
                    if let issue = result.issue { Text(issue).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if let before = batch.before, let after = batch.after {
                Text("Chrome footprint: \(amount(before.footprint)) → \(amount(after.footprint)). RSS отдельно: \(amount(before.rss)) → \(amount(after.rss)).").font(.caption2)
                Text("Вся наблюдаемая группа Chrome, включая другие профили. Учёт частичный; дельта не доказывает эффект выбранной вкладки.").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Подтверждение состояния вкладки не гарантирует освобождение RAM.").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption2).foregroundStyle(contrast == .increased ? Color.primary : color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.08), in: Capsule())
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func filterName(_ value: ChromeTabFilter) -> String {
        switch value {
        case .all: "Все"
        case .available: "Доступные"
        case .protected: "Защищённые"
        case .discarded: "Выгруженные"
        case .selected: "Выбранные"
        }
    }
    private func visibleTabs(_ profile: ChromeProfile) -> [ChromeTab] {
        let now = Date()
        return profile.tabs.filter { tab in
            filter.matches(tab, query: query, policy: profile.policy, stale: profile.stale,
                           selected: model.selected.contains(model.selection(profile, tab)), now: now)
        }.sorted {
            let lhs = $0.lastAccessedMilliseconds ?? .infinity, rhs = $1.lastAccessedMilliseconds ?? .infinity
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
    private func amount(_ metric: DiagnosticMetric) -> String {
        guard let value = metric.value else { return "Неизвестно" }
        return (value / 1_048_576).formatted(.number.precision(.fractionLength(1))) + " MiB"
    }
}
