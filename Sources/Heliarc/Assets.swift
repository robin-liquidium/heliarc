import AppKit

enum HeliarcAssets {
    static let appIcon = load("HeliarcIcon")
    static let logo = load("HeliarcLogo")

    static let menuBarIcon: NSImage? = {
        guard let image = load("MenuBarIcon@2x") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
