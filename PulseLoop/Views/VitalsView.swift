import SwiftUI
import SwiftData

struct VitalsView: View {
    @Binding var path: NavigationPath
    /// Whether the Vitals tab is the one on screen. The `.page` TabView keeps adjacent tabs alive, so
    /// we gate expensive rebuilds on visibility — an off-screen Vitals must not rebuild on every sync.
    let isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @State private var measuring: MeasurementSheet.Kind?
    @State private var dataChange = PulseDataChange.shared
    /// Owns the prepared vitals state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: VitalsStore?

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        guard let activeStore = store else {
            return AnyView(PulseColors.background.ignoresSafeArea().task { ensureStore() })
        }

        return AnyView(GeometryReader { geo in
            let twoColumn = self.useTwoColumns(width: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBlock
                    measureRow(activeStore)
                    grid(activeStore, twoColumn: twoColumn)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
            .background(PulseColors.background)
            .refreshable { await coordinator.pullToRefresh() }
            .task { ensureStore(); if isActive { store?.updateProfile(profile) } }
            .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
            .onChange(of: isActive) { _, active in if active { store?.updateProfile(profile) } }
            .onChange(of: profile?.updatedAt) { _, _ in store?.updateProfile(profile) }
            .sheet(item: Binding(get: { measuring.map(VitalsMeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
                MeasurementSheet(kind: item.kind)
            }
        })
    }

    /// Single column on narrow devices (iPhone SE) or large accessibility text; two otherwise.
    private func useTwoColumns(width: CGFloat) -> Bool {
        if dynamicTypeSize >= .accessibility1 { return false }
        return width >= 380
    }

    // MARK: - Header & measure row

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Vitals").font(.system(size: 26, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
            Text("Live measurements and trends").font(.system(size: 14)).foregroundStyle(PulseColors.textSecondary)
        }
    }

    @ViewBuilder
    private func measureRow(_ store: VitalsStore) -> some View {
        // On-demand spot measurements are capability-gated. A combined "Measure now" button (BP + SpO₂
        // + stress) needs a new BLE command and is deferred; for now we surface the supported spot
        // readings the ring can do today.
        // TODO(combined-measure): replace these with a single "Measure now" pill once the combined
        // measurement command lands.
        let caps = store.capabilities
        if caps.contains(.manualHeartRate) || caps.contains(.manualSpo2) {
            HStack(spacing: 8) {
                if caps.contains(.manualHeartRate) {
                    QuickActionButton(label: "Measure HR", accent: true) { measuring = .hr }
                }
                if caps.contains(.manualSpo2) {
                    QuickActionButton(label: "Measure SpO₂") { measuring = .spo2 }
                }
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ store: VitalsStore, twoColumn: Bool) -> some View {
        let columns: [GridItem] = twoColumn
            ? [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
            : [GridItem(.flexible())]
        let physiology = UserPhysiologyProfile(profile)

        LazyVGrid(columns: columns, spacing: 14) {
            // Full-width chart cards.
            fullWidth(twoColumn) { chartCard(store, .heartRate, physiology) }
            fullWidth(twoColumn) { chartCard(store, .spo2, physiology, showPoints: true) }
            fullWidth(twoColumn) { bpCard(store, physiology) }
            fullWidth(twoColumn) { chartCard(store, .hrv, physiology) }

            // Two-up compact gauges.
            if let stress = card(store, .stress) {
                VitalGaugeCard(model: stress) { open(.stress) }
            }
            if let fatigue = card(store, .fatigue) {
                VitalGaugeCard(model: fatigue) { open(.fatigue) }
            }

            // Glucose: full-width gauge card.
            if let glucose = card(store, .glucose) {
                fullWidth(twoColumn) { VitalGlucoseCard(model: glucose) { open(.glucose) } }
            }

            // Skin temperature (Colmi) — full-width chart.
            if store.visibleMetrics.contains(.temperature) {
                fullWidth(twoColumn) { chartCard(store, .temperature, physiology) }
            }
        }
    }

    /// Wrap a card so it spans both columns when in two-column mode.
    @ViewBuilder
    private func fullWidth<V: View>(_ twoColumn: Bool, @ViewBuilder _ content: () -> V) -> some View {
        if twoColumn {
            content().gridCellColumns(2)
        } else {
            content()
        }
    }

    // MARK: - Card builders

    private func card(_ store: VitalsStore, _ metric: MetricKind) -> VitalCardViewModel? {
        guard store.visibleMetrics.contains(metric.metricKey) else { return nil }
        return store.cards[metric]
    }

    @ViewBuilder
    private func chartCard(_ store: VitalsStore, _ metric: MetricKind,
                           _ physiology: UserPhysiologyProfile, showPoints: Bool = false) -> some View {
        if let model = card(store, metric) {
            let baseline = metric == .hrv ? BaselineStats.compute(store.hrvSamples) : nil
            VitalChartCard(model: model, profile: physiology, baseline: baseline, showPoints: showPoints) { open(metric) }
        }
    }

    @ViewBuilder
    private func bpCard(_ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        if let model = card(store, .bloodPressure) {
            VitalBloodPressureCard(
                model: model,
                systolic: store.systolicSamples.last?.value,
                diastolic: store.diastolicSamples.last?.value,
                systolicZones: VitalsThresholdEngine.zones(for: .bloodPressure, profile: physiology),
                diastolicZones: VitalsThresholdEngine.diastolicReferenceZones(),
                onTap: { open(.bloodPressure) }
            )
        }
    }

    private func open(_ metric: MetricKind) {
        path.append(AppRoute.metricDetail(metric))
    }

    // MARK: - Store lifecycle

    private func ensureStore() {
        if store == nil { store = VitalsStore(modelContext: modelContext, profile: profile) }
    }
}

private struct VitalsMeasuringItem: Identifiable {
    let kind: MeasurementSheet.Kind
    var id: Int { kind == .hr ? 0 : 1 }
}
