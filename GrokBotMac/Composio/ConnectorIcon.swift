import AppKit
import SwiftUI

/// The real logo for a connector (10.1), in the service's own colour on a white tile, like a store listing.
/// An app with no logo, or a system that cannot draw it, falls back to the app's symbol.
struct ConnectorIcon: View {
    let slug: String
    let symbol: String
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let image = ConnectorIconCache.image(slug) {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.21)
                    .frame(width: size, height: size)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).stroke(Color.black.opacity(0.1), lineWidth: 1))
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.42)).frame(width: size, height: size)
                    .background(MacTheme.panel, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            }
        }.accessibilityHidden(true)
    }
}

/// Logos are drawn once from their SVG shape and kept.
@MainActor
enum ConnectorIconCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ slug: String) -> NSImage? {
        if let cached = cache[slug] { return cached }
        guard let logo = ConnectorLogos.all[slug] else { return nil }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" width=\"96\" height=\"96\"><path fill=\"#" + logo.hex + "\" d=\"" + logo.path + "\"/></svg>"
        guard let image = NSImage(data: Data(svg.utf8)), image.isValid, image.size.width > 0 else { return nil }
        cache[slug] = image
        return image
    }
}
