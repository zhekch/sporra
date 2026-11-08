import SwiftUI

private let activityPickerChromeHeight: CGFloat = 64
private let activityPickerMaximumCompactHeight: CGFloat = 620

struct NativeActivityPicker: View {
    @ObservedObject var store: NativeStore
    @State private var loadingDates = true
    @State private var fittedHeight: CGFloat = 340
    @State private var selectedDetent = PresentationDetent.height(340)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(ActivityChoices.groups(store.routeChoices), id: \.sport) { group in
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: NativeSearchPresentation.sportIcon(group.sport))
                                Text(group.sport)
                                Spacer()
                                Text("\(group.routes.count)")
                            }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            VStack(spacing: 0) {
                                ForEach(Array(group.routes.enumerated()), id: \.offset) { index, route in
                                    if index > 0 { Divider().padding(.horizontal, 20) }
                                    activityRow(route).padding(.horizontal, 20).padding(.vertical, 12)
                                }
                            }
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { fitContent(proxy.size.height) }
                        .onChange(of: proxy.size.height) { fitContent($0) }
                })
            }
            .navigationTitle("Multiple activities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.routeChoices = [] }
                }
            }
        }.tint(.primary)
        .presentationDetents([.height(fittedHeight), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .task {
            await store.enrichRouteChoices()
            loadingDates = false
        }
    }
    private func fitContent(_ contentHeight: CGFloat) {
        let height = min(activityPickerMaximumCompactHeight, max(160, contentHeight + activityPickerChromeHeight))
        guard abs(height - fittedHeight) > 0.5 else { return }
        let compact = selectedDetent != .large
        fittedHeight = height
        if compact { selectedDetent = .height(height) }
    }
    private func activityRow(_ route: JSON) -> some View {
        Button {
            store.routeChoices = []
            Task { await store.openActivity(route["id"], preview: route) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(route["name"].text("Activity")).foregroundStyle(.primary)
                        .font(.body.weight(.medium))
                    HStack(spacing: 6) {
                        if route["firstAt"].double > 0 { Text(nativeDate(route["firstAt"])) }
                        else { Text(loadingDates ? "Loading date…" : "Date unavailable") }
                        if route["lengthM"].double > 0 {
                            Text("·")
                            Text(String(format: "%.1f km", route["lengthM"].double / 1000))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
