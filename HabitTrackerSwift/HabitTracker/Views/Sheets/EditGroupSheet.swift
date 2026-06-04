import SwiftUI

struct EditGroupSheet: View {
    @EnvironmentObject var store: HabitStore
    @Environment(\.dismiss) var dismiss

    let group: HabitGroup

    @State private var name: String = ""
    @State private var selectedColor: HabitColor = .blue
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .submitLabel(.done)
                }

                Section {
                    HStack {
                        Label("Серия 100%", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("\(group.streak) дней")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Привычек", systemImage: "list.bullet")
                            .foregroundStyle(.blue)
                        Spacer()
                        Text("\(group.habits.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Статистика")
                }

                Section {
                    ColorPickerGrid(selectedColor: $selectedColor)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("Цвет")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Удалить группу")
                                .font(.system(size: 17))
                            Spacer()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: "1C1C1E"))
            .navigationTitle("Группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(.blue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { saveChanges() }
                        .fontWeight(isDirty ? .bold : .regular)
                        .disabled(!isDirty || !isValid)
                }
            }
            .alert("Удалить группу?", isPresented: $showDeleteAlert) {
                Button("Отмена", role: .cancel) {}
                Button("Разгруппировать") { deleteGroup(keepHabits: true) }
                Button("Удалить всё", role: .destructive) { deleteGroup(keepHabits: false) }
            } message: {
                Text("«\(group.name)» содержит \(group.habits.count) привычек")
            }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear {
            name = group.name
            selectedColor = group.colorName
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespaces) != group.name
            || selectedColor != group.colorName
    }

    private func saveChanges() {
        store.updateGroup(
            group.id,
            name: name.trimmingCharacters(in: .whitespaces),
            color: selectedColor
        )
        dismiss()
    }

    private func deleteGroup(keepHabits: Bool) {
        store.deleteGroup(group.id, keepHabits: keepHabits)
        dismiss()
    }
}

#Preview {
    EditGroupSheet(
        group: HabitGroup(
            name: "Утро",
            colorName: .teal,
            habits: [
                Habit(name: "Медитация", colorName: .teal),
                Habit(name: "Душ", colorName: .cyan)
            ]
        )
    )
    .environmentObject(HabitStore())
}
