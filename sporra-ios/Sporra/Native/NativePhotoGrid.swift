import SwiftUI

/// Keep the complete group available; thumbnails are requested only as cells appear.
struct NativePhotoGrid: View {
    let items: [PhotoLibrary.Located]
    let open: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 3)], spacing: 3) {
                    ForEach(items.indices, id: \.self) { index in
                        Button { open(index) } label: {
                            VStack(spacing: 3) {
                                NativePhotoThumbnail(item: items[index])
                                Text(nativeDate(.number(Double(items[index].t))))
                                    .font(.caption2).foregroundStyle(.primary)
                            }.padding(.bottom, 6)
                        }.buttonStyle(.plain)
                        .accessibilityLabel("\(items[index].isVideo ? "Video" : "Photo") \(index + 1), \(nativeDate(.number(Double(items[index].t))))")
                    }
                }.padding(3)
            }
            .navigationTitle("\(items.count) photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(.primary)
    }
}

private struct NativePhotoThumbnail: View {
    let item: PhotoLibrary.Located
    @State private var image: UIImage?
    @State private var finished = false
    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { proxy in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    }
                } else if finished {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else { ProgressView() }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                        .shadow(radius: 2).padding(7)
                }
            }
            .clipped()
            .task(id: item.id) {
                let result = await PhotoLibrary.jpeg(id: item.id, px: 320)
                guard !Task.isCancelled else { return }
                finished = true
                guard let result else { return }
                image = UIImage(data: result.data)
            }
    }
}
