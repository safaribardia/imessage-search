import AppKit
import CoreGraphics
import SwiftUI

/// Which side of the System Settings window the helper panel sits on; the
/// view's arrow points back toward the settings window.
@MainActor
private final class GuidePlacement: ObservableObject {
    @Published var isBelowSettings = true
}

@MainActor
final class FullDiskAccessGuide {
    static let shared = FullDiskAccessGuide()

    private var panel: NSPanel?
    private var settingsTerminationObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private let placement = GuidePlacement()

    private init() {}

    func show() {
        openFullDiskAccessSettings()

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        observeSystemSettingsTermination()
        startTrackingSystemSettings(panel)
    }

    func dismiss() {
        panel?.close()
        panel = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let settingsTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(settingsTerminationObserver)
            self.settingsTerminationObserver = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 156),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The draggable app row owns pointer drags; allowing background
        // window movement here makes macOS move the entire helper instead.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: FullDiskAccessGuideView(placement: placement)
        )
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let x = visibleFrame.maxX - panel.frame.width - 24
        let y = visibleFrame.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func startTrackingSystemSettings(_ panel: NSPanel) {
        trackingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self, weak panel] _ in
            guard let self, let panel else {
                return
            }
            Task { @MainActor in
                self.positionBelowSystemSettings(panel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
        positionBelowSystemSettings(panel)
    }

    private func positionBelowSystemSettings(_ panel: NSPanel) {
        guard let settingsFrame = systemSettingsFrame() else {
            return
        }

        let primaryTop = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?
            .frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        let settingsBottom = primaryTop - settingsFrame.maxY
        let settingsTop = primaryTop - settingsFrame.minY
        let settingsCenterX = settingsFrame.midX

        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(
                NSPoint(x: settingsCenterX, y: settingsBottom + settingsFrame.height / 2)
            )
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let gap: CGFloat = 10
        let edgeInset: CGFloat = 8

        let x = min(
            max(
                settingsCenterX - panel.frame.width / 2,
                visibleFrame.minX + edgeInset
            ),
            visibleFrame.maxX - panel.frame.width - edgeInset
        )

        let belowY = settingsBottom - gap - panel.frame.height
        let y: CGFloat
        let isBelow = belowY >= visibleFrame.minY + edgeInset
        if isBelow {
            y = belowY
        } else {
            y = min(
                settingsTop + gap,
                visibleFrame.maxY - panel.frame.height - edgeInset
            )
        }
        if placement.isBelowSettings != isBelow {
            placement.isBelowSettings = isBelow
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func systemSettingsFrame() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerName as String] as? String == "System Settings",
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else {
                return nil
            }
            return frame
        }
        .max { $0.width * $0.height < $1.width * $1.height }
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func observeSystemSettingsTermination() {
        guard settingsTerminationObserver == nil else {
            return
        }
        settingsTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
            application.bundleIdentifier == "com.apple.systempreferences" else {
                return
            }
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }
}

private struct FullDiskAccessGuideView: View {
    @ObservedObject var placement: GuidePlacement

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (
                    Text("Drag ")
                        .foregroundColor(.secondary)
                    + Text("iMessage Search")
                        .foregroundColor(.primary)
                        .fontWeight(.medium)
                    + Text(" into full disk access")
                        .foregroundColor(.secondary)
                )
                    .font(.callout)
                Spacer(minLength: 0)
                // Points back at the System Settings window, whichever side
                // of it the panel ended up on.
                Image(systemName: placement.isBelowSettings ? "arrow.up" : "arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            AppBundleDragSource()
                .frame(height: 64)
        }
        .padding(24)
        .frame(width: 360, height: 156)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }
}

private struct AppBundleDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppDragSourceView {
        AppDragSourceView(bundleURL: Bundle.main.bundleURL)
    }

    func updateNSView(_ nsView: AppDragSourceView, context: Context) {}
}

private final class AppDragSourceView: NSView, NSDraggingSource {
    private let bundleURL: URL
    private let icon: NSImage
    private let displayName: String

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        displayName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String ?? "iMessage Search"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 64)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let draggingItem = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        let dragSize = NSSize(width: 56, height: 56)
        draggingItem.setDraggingFrame(
            NSRect(
                x: point.x - dragSize.width / 2,
                y: point.y - dragSize.height / 2,
                width: dragSize.width,
                height: dragSize.height
            ),
            contents: icon
        )
        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let iconRect = NSRect(
            x: 12,
            y: (bounds.height - 42) / 2,
            width: 42,
            height: 42
        )
        icon.draw(in: iconRect)

        let labelRect = NSRect(
            x: iconRect.maxX + 12,
            y: (bounds.height - 20) / 2,
            width: max(0, bounds.width - iconRect.maxX - 24),
            height: 20
        )
        (displayName as NSString).draw(
            in: labelRect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
        needsDisplay = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (
            isDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.04)
        ).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
