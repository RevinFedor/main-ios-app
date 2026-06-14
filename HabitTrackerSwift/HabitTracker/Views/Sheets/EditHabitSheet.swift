import SwiftUI

struct EditHabitSheet: View {
    @EnvironmentObject var store: HabitStore
    @Environment(\.dismiss) var dismiss

    let habit: Habit
    let groupId: UUID?

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var selectedColor: HabitColor = .blue
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // Title + description in ONE section → the native row separator
                // between them IS the "прочерк". Hierarchy is deliberately
                // REVERSED from a normal title: the description is the prominent
                // text (17pt white), the title is the subordinate, label-like
                // element (14pt .secondary grey). User ask: заголовок не должен
                // выделяться размером — он помечен по-другому (цвет+меньше), а
                // описание читается заметнее. Title font is therefore ≤ description.
                Section {
                    TextField("Название", text: $name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .submitLabel(.done)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                    // Grows from ONE line (not a forced 2-line box) so the empty
                    // state has symmetric top/bottom padding — the earlier
                    // lineLimit(2...) reserved a blank 2nd line, which read as
                    // "снизу пединг больше". Native iOS 16+ multi-line field:
                    // built-in placeholder, no TextEditor background hacks.
                    TextField("Описание", text: $notes, axis: .vertical)
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .lineLimit(1...6)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
            // Pull the first section up toward the navbar — the default Form top
            // inset left a large empty band under "Закрыть/Сохранить" (user:
            // "слишком большое расстояние … нужно сделать меньше").
            .contentMargins(.top, 8, for: .scrollContent)
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
            notes = habit.notes ?? ""
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
            || notes.trimmingCharacters(in: .whitespacesAndNewlines) != (habit.notes ?? "")
    }

    private func saveChanges() {
        store.updateHabit(
            habit.id,
            name: name.trimmingCharacters(in: .whitespaces),
            color: selectedColor,
            notes: notes,
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
