import SwiftUI

// Reusable badge that shows how many days remain on the embedded provisioning
// profile before iOS revokes the app's signature. For free Apple-ID dev
// signing this window is 7 days; the user needs to run ./deploy.sh again
// before it hits zero. Placed at the top of every Settings sheet so the
// number is always one tap away — no surprise "Untrusted Developer" lockout.

struct ProvisioningExpiryView: View {
    private let days: Int?
    private let date: Date?

    init() {
        self.days = ProvisioningInfo.daysUntilExpiry()
        self.date = ProvisioningInfo.expirationDate()
    }

    var body: some View {
        if let days, let date {
            HStack(spacing: 10) {
                Image(systemName: icon(days: days))
                    .foregroundStyle(color(days: days))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(days: days))
                        .font(.subheadline.weight(.semibold))
                    Text("Истекает \(formatted(date))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        // No row when ProvisioningInfo can't read the profile — keeps the
        // settings sheet clean on simulator / unsigned local runs.
    }

    private func title(days: Int) -> String {
        switch days {
        case ..<0:  return "Сертификат истёк — запусти ./deploy.sh"
        case 0:     return "Сертификат истекает сегодня"
        case 1:     return "1 день до перебилда"
        case 2...4: return "\(days) дня до перебилда"
        default:    return "\(days) дней до перебилда"
        }
    }

    private func color(days: Int) -> Color {
        if days <= 0 { return .red }
        if days <= 2 { return .orange }
        return .green
    }

    private func icon(days: Int) -> String {
        if days <= 0 { return "exclamationmark.triangle.fill" }
        if days <= 2 { return "clock.badge.exclamationmark" }
        return "checkmark.seal.fill"
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }
}
