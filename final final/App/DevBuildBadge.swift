//
//  DevBuildBadge.swift
//  final final
//
//  Makes a development build visually identifiable at a glance, so that several
//  builds from different worktrees (a parallel superdev batch runs up to nine)
//  can be told apart in the Dock, in Cmd-Tab, and — most importantly — in any
//  screenshot captured as evidence.
//
//  Debug-only by construction: the whole file is inside `#if DEBUG`, so a
//  release build carries none of it. The label comes from GitInfo.plist —
//  written into the built app's Resources by the app target's "Stamp Git
//  Info into GitInfo.plist" post-build phase, sourced from the unsandboxed
//  GitStamp aggregate target's git capture (see GitInfo.devLabel) — and the
//  colour is derived from that label, so a given worktree always gets the
//  same colour across rebuilds.
//

#if DEBUG
    import AppKit

    @MainActor
    enum DevBuildBadge {
        /// Stable per-label colour. Uses FNV-1a rather than Swift's `Hasher`,
        /// which is seeded per-process and would give the same worktree a
        /// different colour on every launch.
        static let color: NSColor = {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in GitInfo.devLabel.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            let hue = CGFloat(hash % 360) / 360
            return NSColor(calibratedHue: hue, saturation: 0.75, brightness: 0.80, alpha: 1)
        }()

        /// Tints the Dock icon and starts labelling windows as they appear.
        /// Call once from `applicationDidFinishLaunching`.
        ///
        /// Skipped under unit tests, where there is no Dock presence worth
        /// touching and the app process is not the thing being looked at. It
        /// deliberately DOES run under UI tests: that is exactly when a labelled
        /// screenshot is worth having. The pill excludes itself from the
        /// accessibility tree so XCUITest element queries are unaffected.
        static func install() {
            guard !TestMode.isUnitTesting else { return }

            if let icon = badgedAppIcon() {
                NSApp.applicationIconImage = icon
            }
            NSApp.windows.forEach(decorate)

            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
            ) { notification in
                let window = notification.object as? NSWindow
                Task { @MainActor in
                    guard let window else { return }
                    decorate(window)
                }
            }
        }

        /// Adds the subtitle and titlebar pill to one window, if it is the kind
        /// of window that has a titlebar and hasn't been decorated already.
        /// Idempotency is checked against the window's own accessory list rather
        /// than a static set, so closed windows need no bookkeeping.
        ///
        /// Excludes `NSPanel` (and its subclasses `NSSavePanel`/`NSOpenPanel`,
        /// plus the print panel) so system panel titles are never rewritten —
        /// an e2e test that scopes an accessibility query to an exact system
        /// panel title would otherwise start failing the moment the badge
        /// appends its suffix shortly after the panel becomes main. None of
        /// the app's own windows are `NSPanel` subclasses, so this only
        /// excludes system panels, not app UI.
        private static func decorate(_ window: NSWindow) {
            guard window.styleMask.contains(.titled), window.canBecomeMain else { return }
            guard !(window is NSPanel) else { return }
            guard !window.titlebarAccessoryViewControllers.contains(where: { $0.view is PillView }) else { return }

            window.subtitle = GitInfo.devLabel

            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            accessory.view = PillView(text: GitInfo.devLabel, color: color)
            window.addTitlebarAccessoryViewController(accessory)
        }

        /// The app icon with a coloured, labelled band across its lower third.
        private static func badgedAppIcon() -> NSImage? {
            guard let base = NSImage(named: NSImage.applicationIconName) else { return nil }

            let side: CGFloat = 512
            let image = NSImage(size: NSSize(width: side, height: side))
            image.lockFocus()
            defer { image.unlockFocus() }

            base.draw(in: NSRect(x: 0, y: 0, width: side, height: side))

            let band = NSRect(x: side * 0.07, y: side * 0.09, width: side * 0.86, height: side * 0.23)
            color.setFill()
            NSBezierPath(roundedRect: band, xRadius: band.height / 2, yRadius: band.height / 2).fill()

            let (text, attributes) = fitted(GitInfo.devLabel.uppercased(), into: band.width - 40, maxSize: 92, minSize: 30)
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: band.midX - textSize.width / 2, y: band.midY - textSize.height / 2),
                withAttributes: attributes
            )
            return image
        }

        /// Shrinks the font until the text fits `width`, then truncates with an
        /// ellipsis if even the smallest size is too wide.
        static func fitted(
            _ text: String, into width: CGFloat, maxSize: CGFloat, minSize: CGFloat
        ) -> (String, [NSAttributedString.Key: Any]) {
            var attributes: [NSAttributedString.Key: Any] = [:]
            var size = maxSize
            while size > minSize {
                attributes = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.white]
                if (text as NSString).size(withAttributes: attributes).width <= width { return (text, attributes) }
                size -= 2
            }
            attributes = [.font: NSFont.systemFont(ofSize: minSize, weight: .bold), .foregroundColor: NSColor.white]

            var truncated = text
            while truncated.count > 1, ((truncated + "…") as NSString).size(withAttributes: attributes).width > width {
                truncated.removeLast()
            }
            return (truncated == text ? text : truncated + "…", attributes)
        }
    }

    /// The titlebar pill. Draws its own text instead of hosting an `NSTextField`
    /// so nothing new appears in the accessibility tree for XCUITest to trip over.
    @MainActor
    final class PillView: NSView {
        private let text: String
        private let fill: NSColor

        init(text: String, color: NSColor) {
            self.text = text.uppercased()
            fill = color
            super.init(frame: .zero)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = (self.text as NSString).size(withAttributes: attributes)
            setFrameSize(NSSize(width: ceil(textSize.width) + 28, height: 28))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { false }

        override func isAccessibilityElement() -> Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let pill = NSRect(
                x: 4, y: (bounds.height - 16) / 2,
                width: bounds.width - 12, height: 16
            )
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            (text as NSString).draw(
                at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }
#endif
