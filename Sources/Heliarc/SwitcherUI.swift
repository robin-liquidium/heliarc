import AppKit
import HeliarcCore
import SwiftUI

final class SwitcherState: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedIndex = 0
    @Published var isVisible = false
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var favicons: [String: NSImage] = [:]
    private var pointerLocationOnShow = NSPoint.zero
    private var hoverEnabled = false
    var onHover: ((Int) -> Void)?

    func show(tabs: [BrowserTab], selectedIndex: Int) {
        pointerLocationOnShow = NSEvent.mouseLocation
        hoverEnabled = false
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        isVisible = true
    }

    func hover(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if !hoverEnabled {
            guard NSEvent.mouseLocation != pointerLocationOnShow else { return }
            hoverEnabled = true
        }
        selectedIndex = index
        onHover?(index)
    }

    func setThumbnails(_ images: [String: NSImage]) {
        thumbnails.merge(images) { _, new in new }
    }

    func setThumbnail(_ image: NSImage, for tabID: String) {
        thumbnails[tabID] = image
    }

    func setFavicon(_ image: NSImage, for tabID: String) {
        favicons[tabID] = image
    }

    func hide() {
        isVisible = false
        tabs = []
        thumbnails = [:]
        favicons = [:]
        selectedIndex = 0
    }
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

private struct TabCard: View {
    let tab: BrowserTab
    let selected: Bool
    let thumbnail: NSImage?
    let favicon: NSImage?
    let width: CGFloat
    private let height: CGFloat = 146
    private let cornerRadius: CGFloat = 10

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        FaviconView(image: favicon, size: 36)
                    }
                }
            }
            .frame(width: width, height: height)

            HStack(spacing: 5) {
                FaviconView(image: favicon, size: 12)

                Text(tab.title.isEmpty ? "Untitled tab" : tab.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(6)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(selected ? Color.white : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1)
        }
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
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    private let padding: CGFloat = 16
    private let cardWidth: CGFloat = 220
    private let cardSpacing: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let width = min(
                cardWidth,
                (geometry.size.width - padding * 2 - cardSpacing * CGFloat(max(0, state.tabs.count - 1)))
                    / CGFloat(max(1, state.tabs.count))
            )
            HStack(spacing: cardSpacing) {
                ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabCard(
                        tab: tab,
                        selected: index == state.selectedIndex,
                        thumbnail: state.thumbnails[tab.id],
                        favicon: state.favicons[tab.id],
                        width: width
                    )
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active = phase { state.hover(index) }
                        }
                    }
            }
            .padding(padding)
        }
        .background(MaterialView())
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.1), lineWidth: 0.5) }
    }
}

final class SwitcherPanel: NSPanel {
    private let state: SwitcherState

    init(state: SwitcherState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 178),
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
        contentView = NSHostingView(rootView: SwitcherView(state: state))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(over browserFrame: NSRect?, tabCount: Int) {
        let cardWidth: CGFloat = 220
        let cardSpacing: CGFloat = 12
        let padding: CGFloat = 16
        let contentWidth = CGFloat(tabCount) * cardWidth
            + CGFloat(max(0, tabCount - 1)) * cardSpacing
            + padding * 2
        let target = browserFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxWidth = min(target.width - 40, 1_200)
        let width = min(contentWidth, maxWidth)
        let size = NSSize(width: width, height: 178)
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: target.midX - width / 2,
            y: target.midY - size.height / 2 + target.height * 0.08
        ))
        orderFrontRegardless()
    }
}

func frontmostHeliumWindowFrame() -> NSRect? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier == HeliumBridge.bundleID,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          let desktopTop = NSScreen.screens.first?.frame.maxY else { return nil }
    for window in windows {
        guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              window[kCGWindowLayer as String] as? Int == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width > 100, frame.height > 100 else { continue }
        return NSRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }
    return nil
}

func frontmostHeliumWindowID() -> CGWindowID? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == HeliumBridge.bundleID }),
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for window in windows {
        guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              window[kCGWindowLayer as String] as? Int == 0,
              let number = window[kCGWindowNumber as String] as? NSNumber,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width > 100, frame.height > 100 else { continue }
        return CGWindowID(number.uint32Value)
    }
    return nil
}
