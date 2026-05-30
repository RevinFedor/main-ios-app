import SwiftUI

struct AddHabitSheet: View {
    @EnvironmentObject var store: HabitStore
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var selectedColor: HabitColor = .blue
    @State private var isCreatingGroup: Bool = false
    @State private var groupHabitNames: [String] = ["", ""]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Form {
                    Section {
                        Picker("Тип", selection: $isCreatingGroup) {
                            Text("Привычка").tag(false)
                            Text("Группа").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }

                    Section {
                        TextField(
                            isCreatingGroup ? "Название группы" : "Название привычки",
                            text: $name
                        )
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .submitLabel(.done)
                    }

                    if isCreatingGroup {
                        Section {
                            ForEach(groupHabitNames.indices, id: \.self) { index in
                                HStack {
                                    TextField("Привычка \(index + 1)", text: $groupHabitNames[index])
                                        .foregroundColor(.white)
                                    if index >= 2 {
                                        Button {
                                            groupHabitNames.remove(at: index)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundColor(.red)
                                                .font(.system(size: 22))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            Button {
                                groupHabitNames.append("")
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Label("Добавить привычку", systemImage: "plus.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        } header: {
                            Text("Привычки в группе")
                        }
                    }

                    Section {
                        ColorPickerGrid(selectedColor: $selectedColor)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    } header: {
                        Text("Цвет")
                    }

                    Section { Color.clear.frame(height: 60) }
                        .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
                .background(Color(hex: "1C1C1E"))

                saveBar
            }
            .background(Color(hex: "1C1C1E"))
            .navigationTitle(isCreatingGroup ? "Новая группа" : "Новая привычка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var saveBar: some View {
        Button {
            addItem()
        } label: {
            Text("Добавить")
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
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isCreatingGroup {
            let validHabits = groupHabitNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return !validHabits.isEmpty
        }
        return true
    }

    private func addItem() {
        if isCreatingGroup {
            let validHabits = groupHabitNames
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            store.addGroup(name: name.trimmingCharacters(in: .whitespaces), color: selectedColor, habitNames: validHabits)
        } else {
            store.addHabit(name: name.trimmingCharacters(in: .whitespaces), color: selectedColor)
        }
        dismiss()
    }
}

// MARK: - Color Picker Grid

struct ColorPickerGrid: View {
    @Binding var selectedColor: HabitColor

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(HabitColor.allCases, id: \.self) { color in
                Button {
                    selectedColor = color
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    ZStack {
                        Circle()
                            .fill(color.color)
                            .frame(width: 36, height: 36)

                        if selectedColor == color {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2.5)
                                .frame(width: 36, height: 36)
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Dark Text Field Style (kept for back-compat with other call sites)

struct DarkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "3A3A3C"))
            )
            .foregroundColor(.white)
            .tint(.blue)
    }
}

#Preview {
    AddHabitSheet()
        .environmentObject(HabitStore())
}
