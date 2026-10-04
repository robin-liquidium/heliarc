import AppKit
import HeliarcCore
import SwiftUI

final class SwitcherState: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedIndex = 0
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var favicons: [String: NSImage] = [:]
    @Published var accents: [String: Color] = [:]
    @Published var faviconAccents: [String: Color] = [:]
    private var pointerLocationOnShow = NSPoint.zero
    private var hoverEnabled = false

    func show(tabs: [BrowserTab], selectedIndex: Int) {
        pointerLocationOnShow = NSEvent.mouseLocation
        hoverEnabled = false
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    func hover(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if !hoverEnabled {
            guard NSEvent.mouseLocation != pointerLocationOnShow else { return }
            hoverEnabled = true
        }
        select(index)
    }

    func select(_ index: Int) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            selectedIndex = index
        }
    }

    func setThumbnails(_ images: [String: NSImage]) {
        thumbnails.merge(images) { _, new in new }
        for (tabID, image) in images {
            accents[tabID] = accentColor(of: image)
        }
    }

    func setThumbnail(_ image: NSImage, for tabID: String) {
        thumbnails[tabID] = image
        accents[tabID] = accentColor(of: image)
    }

    func setFavicon(_ image: NSImage, for tabID: String) {
        favicons[tabID] = image
        faviconAccents[tabID] = accentColor(of: image)
    }

    func hide() {
        tabs = []
        thumbnails = [:]
        favicons = [:]
        accents = [:]
        faviconAccents = [:]
        selectedIndex = 0
    }
}

private enum Metrics {
    static let cardWidth: CGFloat = 220
    static let cardHeight: CGFloat = 146
    static let cardSpacing: CGFloat = 16
    static let padding: CGFloat = 20
    static let cardRadius: CGFloat = 14
    // Concentric with the cards: outer radius = inner radius + padding.
    static let panelRadius = cardRadius + padding
    static let panelHeight = cardHeight + padding * 2
    static let ringGap: CGFloat = 3
    static let ringWidth: CGFloat = 3
}

private let systemAccents: [NSColor] = [
    .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal,
    .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemPink,
]

/// System color closest in hue to the most prominent vivid color in the image.
/// Returns nil for mostly grayscale images so the caller can fall back.
private func accentColor(of image: NSImage) -> Color? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = 96
    let height = 54
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let bucketCount = 24
    var weights = [CGFloat](repeating: 0, count: bucketCount)
    var sums = [(r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: bucketCount)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let r = CGFloat(pixels[i]) / 255
        let g = CGFloat(pixels[i + 1]) / 255
        let b = CGFloat(pixels[i + 2]) / 255
        let brightness = max(r, g, b)
        let chroma = brightness - min(r, g, b)
        guard brightness > 0.25, chroma / brightness > 0.25 else { continue }
        let saturation = chroma / brightness
        var hue: CGFloat
        if brightness == r {
            hue = (g - b) / chroma
        } else if brightness == g {
            hue = 2 + (b - r) / chroma
        } else {
            hue = 4 + (r - g) / chroma
        }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        let weight = saturation * brightness
        let bucket = min(bucketCount - 1, Int(hue * CGFloat(bucketCount)))
        weights[bucket] += weight
        sums[bucket].r += r * weight
        sums[bucket].g += g * weight
        sums[bucket].b += b * weight
    }

    guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
          weights[best] > CGFloat(width * height) * 0.001 else { return nil }
    let weight = weights[best]
    let hue = NSColor(
        srgbRed: sums[best].r / weight,
        green: sums[best].g / weight,
        blue: sums[best].b / weight,
        alpha: 1
    ).hueComponent
    func distance(_ color: NSColor) -> CGFloat {
        let delta = abs((color.usingColorSpace(.sRGB)?.hueComponent ?? 0) - hue)
        return min(delta, 1 - delta)
    }
    return systemAccents.min { distance($0) < distance($1) }.map { Color(nsColor: $0) }
}

private struct MaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct TitlePill: View {
    let title: String
    let favicon: NSImage?

    var body: some View {
        let content = HStack(spacing: 6) {
            FaviconView(image: favicon, size: 13)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)

        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

private struct TabCard: View {
    let tab: BrowserTab
    let selected: Bool
    let thumbnail: NSImage?
    let favicon: NSImage?
    let accent: Color?
    let faviconAccent: Color?
    let width: CGFloat
    let selection: Namespace.ID
    private let height = Metrics.cardHeight
    private let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)

    private var ringColor: Color { accent ?? faviconAccent ?? .accentColor }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                } else {
                    ZStack {
                        if let faviconAccent {
                            LinearGradient(
                                colors: [faviconAccent.opacity(0.45), faviconAccent.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else {
                            Color.primary.opacity(0.08)
                        }

                        FaviconView(image: favicon, size: 44)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                }
            }
            .frame(width: width, height: height)

            TitlePill(title: tab.title.isEmpty ? "Untitled tab" : tab.title, favicon: favicon)
                .padding(7)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
        .overlay {
            if selected {
                // Focus ring sits outside the card with a small gap, like the system focus ring.
                let outset = Metrics.ringGap + Metrics.ringWidth
                RoundedRectangle(cornerRadius: Metrics.cardRadius + outset, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: Metrics.ringWidth)
                    .padding(-outset)
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .scaleEffect(selected ? 1.03 : 1)
        .shadow(color: ringColor.opacity(selected ? 0.5 : 0), radius: 10)
    }
}

private struct FaviconView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    @Namespace private var selection

    var body: some View {
        let content = GeometryReader { geometry in
            let count = CGFloat(max(1, state.tabs.count))
            let width = min(
                Metrics.cardWidth,
                (geometry.size.width - Metrics.padding * 2 - Metrics.cardSpacing * (count - 1)) / count
            )
            HStack(spacing: Metrics.cardSpacing) {
                ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabCard(
                        tab: tab,
                        selected: index == state.selectedIndex,
                        thumbnail: state.thumbnails[tab.id],
                        favicon: state.favicons[tab.id],
                        accent: state.accents[tab.id],
                        faviconAccent: state.faviconAccents[tab.id],
                        width: width,
                        selection: selection
                    )
                        .zIndex(index == state.selectedIndex ? 1 : 0)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active = phase { state.hover(index) }
                        }
                    }
            }
            .padding(Metrics.padding)
        }

        // On macOS 26+ the panel's NSGlassEffectView provides the Liquid Glass background.
        if #available(macOS 26, *) {
            content
        } else {
            let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
            content
                .background(MaterialView())
                .clipShape(shape)
                .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        }
    }
}

final class SwitcherPanel: NSPanel {
    private let state: SwitcherState

    init(state: SwitcherState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: Metrics.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: SwitcherView(state: state))
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Metrics.panelRadius
            glass.contentView = hostingView
            contentView = glass
        } else {
            contentView = hostingView
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(over browserFrame: NSRect?, tabCount: Int) {
        let contentWidth = CGFloat(tabCount) * Metrics.cardWidth
            + CGFloat(max(0, tabCount - 1)) * Metrics.cardSpacing
            + Metrics.padding * 2
        let target = browserFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxWidth = min(target.width - 40, 1_200)
        let width = min(contentWidth, maxWidth)
        let size = NSSize(width: width, height: Metrics.panelHeight)
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: target.midX - width / 2,
            y: target.midY - size.height / 2 + target.height * 0.08
        ))
        orderFrontRegardless()
    }
}

/// Frontmost on-screen Helium window; the window list is ordered front to back.
func frontmostHeliumWindow() -> (id: CGWindowID, frame: NSRect)? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == HeliumBridge.bundleID }),
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          let desktopTop = NSScreen.screens.first?.frame.maxY else { return nil }
    for window in windows {
        guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              window[kCGWindowLayer as String] as? Int == 0,
              let number = window[kCGWindowNumber as String] as? NSNumber,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width > 100, frame.height > 100 else { continue }
        // CoreGraphics uses a top-left origin; AppKit uses bottom-left.
        let appKitFrame = NSRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
        return (CGWindowID(number.uint32Value), appKitFrame)
    }
    return nil
}
