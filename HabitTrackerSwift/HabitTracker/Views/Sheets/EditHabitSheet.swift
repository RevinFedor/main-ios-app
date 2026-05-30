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
            ZStack(alignment: .bottom) {
                Form {
                    Section {
                        TextField("Название", text: $name)
                            .font(.system(size: 17))
                            .foregroundColor(.white)
                            .submitLabel(.done)
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
                                Text("Удалить привычку")
                                    .font(.system(size: 17))
                                Spacer()
                            }
                        }
                    }

                    // Spacer for the floating Save button
                    Section { Color.clear.frame(height: 60) }
                        .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
                .background(Color(hex: "1C1C1E"))

                saveBar
            }
            .background(Color(hex: "1C1C1E"))
            .navigationTitle("Привычка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
            .alert("Удалить привычку?", isPresented: $showDeleteAlert) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) { deleteHabit() }
            } message: {
                Text("«\(habit.name)» будет удалена навсегда")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear {
            name = habit.name
            selectedColor = habit.colorName
        }
    }

    private var saveBar: some View {
        Button {
            saveChanges()
        } label: {
            Text("Сохранить")
        }
        .buttonStyle(ProminentCTAStyle(enabled: isValid, tint: .blue))
        .disabled(!isValid)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [Color(hex: "1C1C1E").opacity(0), Color(hex: "1C1C1E")],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
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
