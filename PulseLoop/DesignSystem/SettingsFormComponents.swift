import SwiftUI

// Shared Liquid Glass building blocks for Settings detail screens. Every Settings sub-page
// previously carried its own private `settingCard` / `toggleRow` / `labeledRow` helper — all
// structurally identical. These consolidate them so the glass surface, corner radius, padding,
// and typography stay consistent across every settings screen from one place.

/// Content wrapped in a glass settings surface (content + padding + Liquid Glass).
/// Replaces the per-view `settingCard` / `formCard` / `numberCard` container helpers.
struct SettingsCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .pulseGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Accent-tinted toggle inside a glass settings row. Shared across all Settings screens.
struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textPrimary)
        }
        .tint(PulseColors.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Settings row with a menu selector that owns a compact, single-line value label.
/// SwiftUI's `.menu` Picker renders its selected label with its own layout and ignores
/// ancestor font/lineLimit, so long option names (e.g. "On-device (Apple)",
/// "gemini-2.5-flash") wrap into the chevron and the variable height makes the row jump.
/// This renders the current `value` itself and truncates it, keeping every row one line.
/// `menuContent` supplies the options (typically a tagged `Picker`, shown inline with a
/// checkmark inside the menu).
struct SettingsMenuRow<MenuContent: View>: View {
    let title: String
    let value: String
    @ViewBuilder var menuContent: MenuContent

    var body: some View {
        SettingsLabeledRow(title: title) {
            Menu {
                menuContent
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(PulseFont.caption2)
                        .imageScale(.small)
                }
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.accent)
            }
        }
    }
}

/// Title + trailing control inside a glass settings row (picker, value, stepper, etc).
/// Replaces the per-view `labeledRow` helper.
struct SettingsLabeledRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textPrimary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Glass as a BACKGROUND layer, not wrapping the row content: an interactive
        // Menu/Picker placed *inside* an iOS 26 `glassEffect` can vanish when its
        // popover opens or the selection changes. Keeping the glass behind the
        // foreground controls avoids that while looking identical.
        .background { Color.clear.pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }
}
