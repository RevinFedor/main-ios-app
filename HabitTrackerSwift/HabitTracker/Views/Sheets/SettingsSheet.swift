import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var store: HabitStore
    @Environment(\.dismiss) var dismiss

    @State private var toastMessage: String?
    @State private var showToast = false
    @State private var showLogs = false

    @State private var showImportConfirm = false
    @State private var importPreview: ImportPreview?

    struct ImportPreview {
        let data: ExportData
        let habitsCount: Int
        let groupsCount: Int
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        ProvisioningExpiryView()
                    }
                    Section {
                        Picker("Отображение дней", selection: $store.firstDayOfWeek) {
                            Text("С понедельника").tag(FirstDayOfWeek.monday)
                            Text("С воскресенья").tag(FirstDayOfWeek.sunday)
                            Text("Относительно сегодня").tag(FirstDayOfWeek.relative)
                        }
                        .onChange(of: store.firstDayOfWeek) { _, _ in
                            store.saveData()
                        }
                    } header: {
                        Text("Отображение")
                    } footer: {
                        Text("Как сетка дней раскладывается в приложении и виджетах.")
                    }

                    Section {
                        Button { copyToClipboard() } label: {
                            dataRow(icon: "doc.on.clipboard", tint: .blue,
                                    title: "Копировать в буфер",
                                    subtitle: "JSON для быстрого доступа")
                        }
                        ShareLink(item: exportJSON()) {
                            dataRow(icon: "square.and.arrow.up", tint: .green,
                                    title: "Отправить файл",
                                    subtitle: "AirDrop, Telegram, Mail...")
                        }
                        Button { prepareImport() } label: {
                            dataRow(icon: "square.and.arrow.down", tint: .orange,
                                    title: "Импорт из буфера",
                                    subtitle: "Восстановить из JSON")
                        }
                    } header: {
                        Text("Данные")
                    } footer: {
                        Text("Экспорт сохранит привычки, группы и настройки. Импорт заменит текущие данные.")
                    }

                    Section {
                        HStack {
                            Text("Версия")
                            Spacer()
                            Text("1.0").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Привычки")
                            Spacer()
                            Text("\(totalHabitsCount)").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Группы")
                            Spacer()
                            Text("\(store.groups.count)").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("О приложении")
                    }

                    Section {
                        HStack(spacing: 12) {
                            Button {
                                showLogs = true
                            } label: {
                                Label("Показать лог", systemImage: "doc.text.magnifyingglass")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIPasteboard.general.string = VRLog.readRecent(maxLines: 400)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 36, height: 32)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)

                            Button(role: .destructive) {
                                VRLog.clear()
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 36, height: 32)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    } header: {
                        Text("Диагностика")
                    } footer: {
                        Text("Тапни иконку лупы — откроется полный просмотрщик. Иконки справа: скопировать недавний лог или очистить без открытия.")
                    }
                }

                if showToast, let message = toastMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(Color(hex: "3A3A3C"))
                            )
                            .padding(.bottom, 30)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogs) {
                DiagnosticsLogView()
            }
            .alert("Импорт данных", isPresented: $showImportConfirm) {
                Button("Отмена", role: .cancel) {
                    importPreview = nil
                }
                Button("Заменить всё", role: .destructive) {
                    performImport()
                }
            } message: {
                if let preview = importPreview {
                    Text(importConfirmMessage(preview: preview))
                }
            }
        }
    }

    private func dataRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var totalHabitsCount: Int {
        store.standaloneHabits.count + store.groups.reduce(0) { $0 + $1.habits.count }
    }

    private func exportJSON() -> String {
        let data = ExportData(
            version: 2,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            standaloneHabits: store.standaloneHabits,
            groups: store.groups,
            firstDayOfWeek: store.firstDayOfWeek
        )
        if let jsonData = try? JSONEncoder().encode(data),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = exportJSON()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToastMessage("✓ Скопировано в буфер")
    }

    private func prepareImport() {
        guard let jsonString = UIPasteboard.general.string, !jsonString.isEmpty else {
            showToastMessage("✗ Буфер пуст")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let data = try? JSONDecoder().decode(ExportData.self, from: jsonData) else {
            showToastMessage("✗ Неверный формат JSON")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let habitsCount = data.standaloneHabits.count + data.groups.reduce(0) { $0 + $1.habits.count }
        importPreview = ImportPreview(data: data, habitsCount: habitsCount, groupsCount: data.groups.count)
        showImportConfirm = true
    }

    private func importConfirmMessage(preview: ImportPreview) -> String {
        let currentHabits = totalHabitsCount
        let currentGroups = store.groups.count
        var m = "Будет импортировано:\n"
        m += "• \(preview.habitsCount) привычек\n"
        m += "• \(preview.groupsCount) групп\n\n"
        m += "Будет удалено:\n"
        m += "• \(currentHabits) привычек\n"
        m += "• \(currentGroups) групп\n\n"
        m += "Это действие нельзя отменить."
        return m
    }

    private func performImport() {
        guard let preview = importPreview else { return }
        store.standaloneHabits = preview.data.standaloneHabits
        store.groups = preview.data.groups
        store.firstDayOfWeek = preview.data.firstDayOfWeek
        store.saveData()
        importPreview = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToastMessage("✓ Импортировано \(preview.habitsCount) привычек")
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.3)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.3)) { showToast = false }
        }
    }
}

struct ExportData: Codable {
    let version: Int
    let exportedAt: String
    let standaloneHabits: [Habit]
    let groups: [HabitGroup]
    let firstDayOfWeek: FirstDayOfWeek
}

#Preview {
    SettingsSheet()
        .environmentObject(HabitStore())
}
