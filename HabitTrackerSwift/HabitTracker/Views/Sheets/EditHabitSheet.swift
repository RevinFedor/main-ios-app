import SwiftUI

struct EditHabitSheet: View {
    @EnvironmentObject var store: HabitStore
    @Environment(\.dismiss) var dismiss

    let habit: Habit
    let groupId: UUID?

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
                    ColorPickerGrid(selectedColor: $selectedColor)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("Цвет")
                }

                Section {
                    HStack {
                        Label("Серия", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("\(habit.streak) дней")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Выполнено", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Text("\(habit.doneCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Статистика")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Удалить привычку")
                                .font(.system(size: 17))
                            Spacer()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: "1C1C1E"))
            .navigationTitle("Привычка")
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
            .alert("Удалить привычку?", isPresented: $showDeleteAlert) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) { deleteHabit() }
            } message: {
                Text("«\(habit.name)» будет удалена навсегда")
            }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear {
            name = habit.name
            selectedColor = habit.colorName
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // The Save button is plain until the user actually changes something, then
    // it goes bold+enabled (Apple-standard "you have unsaved edits" affordance).
    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespaces) != habit.name
            || selectedColor != habit.colorName
    }

    private func saveChanges() {
        store.updateHabit(
            habit.id,
            name: name.trimmingCharacters(in: .whitespaces),
            color: selectedColor,
            groupId: groupId
        )
        dismiss()
    }

    private func deleteHabit() {
        store.deleteHabit(habit.id, groupId: groupId)
        dismiss()
    }
}

#Preview {
    EditHabitSheet(
        habit: Habit(name: "Зарядка", colorName: .blue),
        groupId: nil
    )
    .environmentObject(HabitStore())
}
