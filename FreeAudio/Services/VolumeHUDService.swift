import AppKit
import SwiftUI

/// Volume feedback when FreeAudio handles the volume keys (outputs with software volume): a small
/// panel at the top right of the menu bar screen, in the style of the macOS 26/27 volume HUD.
/// The system's own HUD can't be triggered by apps, and the older OSDUIHelper draws the
/// pre-macOS 26 centered OSD (spike S9).
@MainActor
final class VolumeHUDService: @unchecked Sendable {
    static let shared = VolumeHUDService()
    private init() {}

    private var panel: NSPanel?
    private var hostingView: NSHostingView<VolumeHUDView>?
    private var hideTask: Task<Void, Never>?
    private static let size = NSSize(width: 280, height: 64)

    /// Shows (or updates) the HUD and hides it 1.5 s after the last call.
    func show(volume: Double, muted: Bool, deviceName: String) {
        let view = VolumeHUDView(volume: volume, muted: muted, deviceName: deviceName)
        let panel = self.panel ?? makePanel(with: view)
        hostingView?.rootView = view
        position(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            })
        }
    }

    private func makePanel(with view: VolumeHUDView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        self.panel = panel
        hostingView = hosting
        return panel
    }

    /// Top right of the screen with the menu bar, just below it.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - 10, y: visible.maxY - Self.size.height - 10))
    }
}

struct VolumeHUDView: View {
    let volume: Double
    let muted: Bool
    let deviceName: String

    private var icon: String {
        if muted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 7) {
                Text(deviceName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule()
                            .fill(Color.primary.opacity(muted ? 0.35 : 0.9))
                            .frame(width: geometry.size.width * (muted ? 0 : min(max(volume, 0), 1)))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 280, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? L("\(deviceName) sessiz", "\(deviceName) muted")
                                  : L("\(deviceName) ses düzeyi %\(Int((volume * 100).rounded()))", "\(deviceName) volume \(Int((volume * 100).rounded())) percent"))
    }
}
