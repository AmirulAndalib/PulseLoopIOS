import SwiftUI

/// Standard page chrome for pushed screens: a glass circular back button on the
/// left, a centered title with consistent typography, and an optional trailing
/// control. Used in place of the system navigation bar so every detail/settings
/// page reads the same — and, since there's no nav-bar content inset, the zoom
/// transition into a page never reflows the content.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Centered title — one canonical style for every page.
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PulseColors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                        .frame(width: 36, height: 36)
                        .pulseGlass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

extension View {
    /// Standard glass page chrome (centered title + glass back button), replacing
    /// the system nav bar. Apply to the screen's root content.
    func pageChrome(_ title: String) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title) { EmptyView() }
            self
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Same, with a trailing control (e.g. an edit/delete button) in the header —
    /// for pages that used to put actions in the system toolbar.
    func pageChrome<T: View>(_ title: String, @ViewBuilder trailing: @escaping () -> T) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title, trailing: trailing)
            self
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
