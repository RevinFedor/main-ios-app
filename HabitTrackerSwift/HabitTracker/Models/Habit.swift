import SwiftUI
import UniformTypeIdentifiers

// MARK: - Habit Status
enum HabitStatus: String, Codable {
    case done
    case missed
}

// MARK: - Habit Colors
enum HabitColor: String, Codable, CaseIterable {
    case blue, cyan, teal, green, lime, yellow, orange, red, pink, purple, indigo

    var color: Color {
        switch self {
        case .blue: return Color(hex: "007AFF")
        case .cyan: return Color(hex: "00D4FF")
        case .teal: return Color(hex: "5AC8FA")
        case .green: return Color(hex: "34C759")
        case .lime: return Color(hex: "A8E063")
        case .yellow: return Color(hex: "FFCC00")
        case .orange: return Color(hex: "FF9500")
        case .red: return Color(hex: "FF3B30")
        case .pink: return Color(hex: "FF2D92")
        case .purple: return Color(hex: "AF52DE")
        case .indigo: return Color(hex: "5856D6")
        }
    }
}

// MARK: - Habit Model
struct Habit: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var colorName: HabitColor
    // Free-text description shown under the title in the edit sheet. MUST be
    // Optional: the synthesized Codable decoder uses decodeIfPresent for optionals,
    // so habits stored BEFORE this field existed decode cleanly (notes == nil).
    // A non-optional String would throw keyNotFound on old JSON → the whole
    // `try? decode(StorageData)` returns nil → every habit silently wiped.
    // Keep this field synced with the duplicated Habit in HabitWidget_.swift
    // (see docs/knowledge/fix-ios-stability.md §3).
    var notes: String?
    var history: [String: HabitStatus]
    var createdAt: Date
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        colorName: HabitColor = .blue,
        notes: String? = nil,
        history: [String: HabitStatus] = [:],
        createdAt: Date = Date(),
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.notes = notes
        self.history = history
        self.createdAt = createdAt
        self.order = order
    }

    var color: Color { colorName.color }

    // Calculate streak
    var streak: Int {
        let calendar = Calendar.current
        var streak = 0
        var checkDate = Date()
        let todayKey = DateHelper.dateKey(for: checkDate)

        // If today not done, start from yesterday
        if history[todayKey] != .done {
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }

        while true {
            let key = DateHelper.dateKey(for: checkDate)
            if history[key] == .done {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }

        return streak
    }

    var doneCount: Int {
        history.values.filter { $0 == .done }.count
    }
}

// MARK: - Transferable for Drag & Drop
extension Habit: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .habit)
    }
}

extension UTType {
    static var habit: UTType {
        UTType(exportedAs: "com.habittracker.habit")
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
