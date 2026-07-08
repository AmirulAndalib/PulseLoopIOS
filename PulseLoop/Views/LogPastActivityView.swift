import SwiftUI
import SwiftData

struct LogPastActivityView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var path: NavigationPath

    @State private var selectedType = "run"
    @State private var startedAt = Date().addingTimeInterval(-3600)
    @State private var durationMinutes = 60
    @State private var saveError: String?

    private let quickDurations = [15, 30, 45, 60, 90]
    private var endedAt: Date { startedAt.addingTimeInterval(Double(durationMinutes) * 60) }
    private var isValid: Bool { durationMinutes > 0 && endedAt <= Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What did you do?")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(PulseColors.textPrimary)
                    Text("Choose an activity, when it started, and how long it lasted.")
                        .font(.system(size: 14))
                        .foregroundStyle(PulseColors.textMuted)
                }

                sectionLabel("Activity type")
                activityGrid

                sectionLabel("When")
                VStack(spacing: 0) {
                    fieldRow(title: "Started", systemImage: "calendar") {
                        DatePicker(
                            "Started",
                            selection: $startedAt,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .tint(PulseColors.accent)
                    }
                    Divider().overlay(PulseColors.borderSubtle).padding(.leading, 52)
                    fieldRow(title: "Ends", systemImage: "clock") {
                        Text(endedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isValid ? PulseColors.textSecondary : PulseColors.warning)
                    }
                }
                .background(PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))

                sectionLabel("Duration")
                durationCard

                if !isValid {
                    Label("The workout must finish before now.", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PulseColors.warning)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PulseColors.danger)
                }

                PrimaryButton(title: "Log Activity", systemImage: "checkmark") { save() }
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.45)
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .background(PulseColors.background.ignoresSafeArea())
        .navigationTitle("Log Past Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activityGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(ActivityMeta.allKinds) { kind in
                let isSelected = kind.type == selectedType
                Button { selectedType = kind.type } label: {
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(isSelected ? PulseColors.accent : PulseColors.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(isSelected ? PulseColors.accentSoft : PulseColors.cardSoft, in: Circle())
                        Text(kind.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(isSelected ? PulseColors.accentSoft : PulseColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(isSelected ? PulseColors.accent : PulseColors.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var durationCard: some View {
        VStack(spacing: 16) {
            HStack {
                Button { durationMinutes = max(5, durationMinutes - 5) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseColors.textPrimary)
                .background(PulseColors.cardSoft, in: Circle())

                Spacer()
                VStack(spacing: 2) {
                    Text(durationText)
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                    Text("DURATION")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(PulseColors.textMuted)
                }
                Spacer()

                Button { durationMinutes += 5 } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseColors.textPrimary)
                .background(PulseColors.cardSoft, in: Circle())
            }

            HStack(spacing: 8) {
                ForEach(quickDurations, id: \.self) { minutes in
                    Button("\(minutes)m") { durationMinutes = minutes }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(durationMinutes == minutes ? Color.white : PulseColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(durationMinutes == minutes ? PulseColors.accent : PulseColors.cardSoft, in: Capsule())
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private var durationText: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) hr" }
        return "\(hours) hr \(minutes) min"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(PulseColors.textMuted)
    }

    private func fieldRow<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(PulseColors.accent)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PulseColors.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }

    private func save() {
        do {
            let session = try ManualActivityService.create(
                type: selectedType,
                startedAt: startedAt,
                durationMinutes: Double(durationMinutes),
                context: modelContext
            )
            path.removeLast()
            path.append(AppRoute.activityDetail(session.id))
        } catch {
            saveError = error.localizedDescription
        }
    }
}
