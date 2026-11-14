import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum AvatarArtwork {
    static func color(_ name: String) -> Color { BotGlyph.color(name) }

    private static func safeDimensions(_ source: CGImageSource) -> Bool {
        guard let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = values[kCGImagePropertyPixelWidth as String] as? Int,
              let height = values[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return width > 0 && height > 0 && width <= 32768 && height <= 32768 && width * height <= 40_000_000
    }
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), safeDimensions(source) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ] as CFDictionary)
    }

    static func importImage(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let resource = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = resource.fileSize, size <= 12_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), safeDimensions(source),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
              ] as CFDictionary) else { throw AvatarImportError.unreadable }
        for quality in [0.8, 0.6, 0.4, 0.2] {
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { throw AvatarImportError.unreadable }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), result.length <= 24_576 { return result as Data }
        }
        throw AvatarImportError.unreadable
    }
}

private enum AvatarImportError: LocalizedError {
    case unreadable
    var errorDescription: String? { "Choose an image under 12 MB. Try a smaller JPEG, PNG, or HEIC image." }
}

struct CustomBotAvatar: View {
    let appearance: BotAppearance
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let data = appearance.imageData, let image = AvatarArtwork.image(data) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
            } else {
                BotGlyphFace(shape: appearance.shape.rawValue, color: appearance.color, size: size)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Shared editor: the Mac saves locally; iOS sends the same appearance to the Mac.
struct BotAvatarPicker: View {
    let bot: Bot
    var save: (BotAppearance?) async -> Bool
    var close: () -> Void
    @State private var draft: BotAppearance
    @State private var reset = false
    @State private var tab = "Bot"
    @State private var importing = false
    @State private var saving = false
    @State private var error: String?

    init(bot: Bot, save: @escaping (BotAppearance?) async -> Bool, close: @escaping () -> Void) {
        self.bot = bot; self.save = save; self.close = close
        _draft = State(initialValue: bot.appearance ?? BotAppearance(color: bot.color))
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text("Bot avatar").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).background(.quaternary, in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Close avatar picker").disabled(saving)
            }
            CustomBotAvatar(appearance: draft, size: 100).padding(.vertical, 12)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(["Bot", "Generate", "Upload"], id: \.self) { item in
                        Button {
                            if item == "Upload" { importing = true }
                            else { tab = item }
                        } label: {
                            Text(item).font(.system(size: 14)).padding(.horizontal, 10).padding(.vertical, 9)
                                .background(tab == item ? Color.primary.opacity(0.07) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    Button("Reset") {
                        draft = BotAppearance(shape: bot.isMain == true ? .circle : .square, color: bot.isMain == true ? "white" : "purple")
                        reset = true; tab = "Bot"
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(12)
                Divider()
                ScrollView {
                    VStack(spacing: 24) {
                        if tab == "Generate" {
                            Text("Generate a new shape and color combination.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Generate a look") {
                                draft = BotAppearance(shape: BotAvatarShape.allCases.randomElement() ?? .hexagon,
                                                      color: BotAppearance.colors.filter { $0 != "white" }.randomElement() ?? "purple")
                                reset = false
                            }.buttonStyle(.bordered)
                        }
                        shapes
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 16) {
                            ForEach(BotAppearance.colors, id: \.self) { color in
                                Button { draft.color = color; draft.imageData = nil; reset = false } label: {
                                    Circle().fill(AvatarArtwork.color(color)).frame(width: 30, height: 30)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                                        .padding(5).overlay(Circle().stroke(draft.color == color && draft.imageData == nil ? Color.primary.opacity(0.4) : .clear, lineWidth: 1.5))
                                }.buttonStyle(.plain).accessibilityLabel(color.capitalized)
                                    .accessibilityAddTraits(draft.color == color ? [.isSelected] : [])
                            }
                        }
                    }.padding(18)
                }.frame(maxHeight: 430)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.08), lineWidth: 1))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button(saving ? "Saving…" : "Save avatar") {
                saving = true; error = nil
                Task {
                    if await save(reset ? nil : draft) { close() }
                    else { error = "The avatar could not be saved. Check your connection and try again." }
                    saving = false
                }
            }.buttonStyle(.borderedProminent).disabled(saving)
        }.padding(18)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                draft.imageData = try AvatarArtwork.importImage(url); reset = false; error = nil; tab = "Bot"
            } catch { self.error = error.localizedDescription }
        }
    }

    private var shapes: some View {
        VStack(spacing: 18) {
            ForEach(0..<3) { row in
                HStack(spacing: 8) {
                    ForEach(Array(BotAvatarShape.allCases.dropFirst(row * 5).prefix(5)), id: \.self) { shape in
                        Button { draft.shape = shape; draft.imageData = nil; reset = false } label: {
                            CustomBotAvatar(appearance: BotAppearance(shape: shape, color: draft.color), size: 38)
                                .padding(4).overlay(RoundedRectangle(cornerRadius: 15).stroke(draft.shape == shape && draft.imageData == nil ? Color.primary.opacity(0.35) : .clear, lineWidth: 1.5))
                        }.buttonStyle(.plain).accessibilityLabel(shape.label)
                            .accessibilityAddTraits(draft.shape == shape ? [.isSelected] : [])
                    }
                }
            }
        }
    }
}
