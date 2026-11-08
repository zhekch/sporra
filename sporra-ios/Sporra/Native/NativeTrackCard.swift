import SwiftUI

struct NativeTrackCard: View {
    @ObservedObject var store: NativeStore
    @State private var expanded = false
    @State private var dragOffset = CGSize.zero
    @State private var days: [String] = []
    @State private var daysError: String?
    private var isTrip: Bool { store.trackDay == nil }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        store.trackDay.map(TrackCardNavigation.dayLabel)
                            ?? store.track["label"].text("Your track")
                    )
                    .font(.title3.weight(.semibold)).lineLimit(2)
                    Text(String(format: "%.1f km", store.track["km"].double))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                NativeMapCardButton(title: "Close track", icon: "xmark") { store.closeSelection() }
            }
            .modifier(
                NativeMapCardDrag(offset: $dragOffset, horizontal: false) { swipe in
                    switch swipe {
                    case .expand: if isTrip { expandDays() }
                    case .collapse:
                        if expanded {
                            withAnimation { expanded = false }
                        } else {
                            store.closeSelection()
                        }
                    default: break
                    }
                })
            if expanded && isTrip {
                Divider()
                if let daysError { Text(daysError).font(.footnote).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            Button {
                                Task { await store.selectTrack(day: day) }
                            } label: {
                                HStack {
                                    Text(TrackCardNavigation.dayLabel(day))
                                    Spacer()
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(220, CGFloat(days.count) * 44))
            }
        }
        .padding(16).modifier(NativeMapCardSurface())
        .offset(dragOffset)
        .modifier(
            NativeMapCardDrag(offset: $dragOffset, vertical: false, simultaneous: true) { swipe in
                switch swipe {
                case .previous: Task { await store.step(-1) }
                case .next: Task { await store.step(1) }
                default: break
                }
            }
        )
        .accessibilityAction(named: "Previous") { Task { await store.step(-1) } }
        .accessibilityAction(named: "Next") { Task { await store.step(1) } }
        .accessibilityAction(named: "Expand trip days") { if isTrip { expandDays() } }
        .accessibilityAction(named: "Collapse trip days") { withAnimation { expanded = false } }
    }

    private func expandDays() {
        days = TrackCardNavigation.days(in: store.track)
        daysError = nil
        withAnimation { expanded = true }
        if !days.isEmpty {
            store.prefetchTrackDays(days)
            return
        }
        let trip = store.track
        Task {
            let cached = await store.api.cachedGet("/api/days")
            let data: JSON?
            if let cached { data = cached } else { data = try? await store.api.get("/api/days") }
            guard store.track["id"] == trip["id"], store.trackDay == nil else { return }
            days = TrackCardNavigation.days(
                in: trip, recorded: Array((data?["days"].object ?? [:]).keys))
            store.prefetchTrackDays(days)
            daysError = days.isEmpty ? "No recorded days are available for this trip." : nil
        }
    }
}
