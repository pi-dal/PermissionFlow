#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

@available(macOS 13.0, *)
@MainActor
final class FloatingDropPanel: NSPanel {
    private weak var panelController: PermissionFlowController?
    private let hostingView: NSHostingView<AnyView>
    private let sizingView: NSHostingView<AnyView>
    private let initialPanelWidth: CGFloat = 420

    private let minimumPanelHeight: CGFloat = 96
    private let sizingHeightLimit: CGFloat = 4096

    /// Launch animation constants tuned to feel responsive without making the
    /// panel overshoot or jitter while the target window is still settling.
    private let animationDuration: TimeInterval = 0.72
    private let animationResponse: Double = 0.72
    private let initialAlpha: CGFloat = 0.9
    private let minimumLaunchScale: CGFloat = 0.58
    private var launchTimer: Timer?
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = NSRect.zero
    private var launchToFrame = NSRect.zero
    private var isAnimatingLaunch = false
    private var localeIdentifier: String?

    init(controller: PermissionFlowController) {
        panelController = controller
        localeIdentifier = controller.localeIdentifier
        let panelView = Self.makePanelView(controller: controller, localeIdentifier: controller.localeIdentifier)
        hostingView = NSHostingView(rootView: panelView)
        sizingView = NSHostingView(rootView: panelView)
        super.init(
            contentRect: CGRect(origin: .zero, size: CGSize(width: initialPanelWidth, height: minimumPanelHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView
        setContentSize(CGSize(width: initialPanelWidth, height: measuredPanelHeight(for: initialPanelWidth)))
    }

    /// Updates the locale environment used by the floating panel content.
    func updateLocaleIdentifier(_ localeIdentifier: String?) {
        guard self.localeIdentifier != localeIdentifier else { return }
        self.localeIdentifier = localeIdentifier
        guard let panelController else { return }
        let panelView = Self.makePanelView(controller: panelController, localeIdentifier: localeIdentifier)
        hostingView.rootView = panelView
        sizingView.rootView = panelView
        setContentSize(CGSize(width: frame.width, height: measuredPanelHeight(for: frame.width)))
    }

    /// The panel intentionally stays non-activating so System Settings remains
    /// the visible focus owner underneath it.
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// If the system temporarily tries to key this panel, immediately ask the
    /// controller to keep System Settings visually frontmost underneath it.
    override func becomeKey() {
        super.becomeKey()
        panelController?.keepSettingsVisible()
    }

    /// Mirrors becomeKey() for main-window promotion attempts so the helper
    /// remains non-disruptive to the actual System Settings interaction.
    override func becomeMain() {
        super.becomeMain()
        panelController?.keepSettingsVisible()
    }

    /// Keeps System Settings visually present when the panel receives a mouse
    /// down event, while still forwarding the event through normal handling.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            panelController?.keepSettingsVisible()
        }
        super.sendEvent(event)
    }

    /// Shows the panel at its current frame without any positioning changes.
    func show() {
        orderFrontRegardless()
    }

    /// Displays the panel at the source frame used to start the launch motion.
    /// This is used before the target System Settings frame is known.
    func show(at sourceFrameInScreen: CGRect) {
        stopLaunchAnimation()
        isAnimatingLaunch = false
        alphaValue = 1
        setContentSize(CGSize(width: frame.width, height: measuredPanelHeight(for: frame.width)))
        setFrame(launchSourceFrame(for: sourceFrameInScreen), display: false)
        orderFrontRegardless()
    }

    /// Animates the panel from the triggering UI element toward the current
    /// System Settings window frame once the destination becomes available.
    func present(from sourceFrameInScreen: CGRect, to settingsFrame: CGRect) {
        stopLaunchAnimation()
        let targetFrame = targetFrame(for: settingsFrame)

        guard sourceFrameInScreen.isEmpty == false else {
            isAnimatingLaunch = false
            alphaValue = 1
            setFrame(targetFrame, display: false)
            orderFrontRegardless()
            return
        }

        isAnimatingLaunch = true
        launchFromFrame = launchSourceFrame(for: sourceFrameInScreen)
        launchToFrame = targetFrame
        launchStartTime = CACurrentMediaTime()
        alphaValue = initialAlpha
        setFrame(launchFromFrame, display: false)
        orderFrontRegardless()
        stepLaunchAnimation()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepLaunchAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        launchTimer = timer
    }

    /// Switches the panel into a drag-friendly mode where mouse events pass
    /// through so System Settings can receive the drop destination interaction.
    func setDraggingPassthrough(_ isDragging: Bool) {
        ignoresMouseEvents = isDragging
        alphaValue = isDragging ? 0.72 : 1.0
        if isDragging {
            orderBack(nil)
        } else {
            orderFrontRegardless()
        }
    }

    /// Repositions the panel under the latest tracked System Settings frame.
    /// While the launch animation is still running, only the destination is
    /// updated so the motion stays continuous.
    func snap(to settingsFrame: CGRect) {
        let target = targetFrame(for: settingsFrame)
        if isAnimatingLaunch {
            // Tracking updates can arrive during the launch. Updating the final
            // destination preserves the motion instead of abruptly snapping.
            launchToFrame = target
            return
        }

        stopLaunchAnimation()
        setFrame(target, display: false)
        orderFrontRegardless()
    }

    /// Calculates the final panel frame relative to the System Settings window.
    /// The panel aligns to the trailing content area, stays underneath the
    /// window, and is clamped to the visible frame of the matching screen.
    private func targetFrame(for settingsFrame: CGRect) -> CGRect {
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(settingsFrame) })?
            .visibleFrame ?? settingsFrame

        let initialWidth = FloatingDropPanelFrameResolver.targetWidth(
            for: settingsFrame,
            screenFrame: screenFrame
        )
        let height = measuredPanelHeight(for: initialWidth)

        return FloatingDropPanelFrameResolver.targetFrame(
            for: settingsFrame,
            measuredPanelHeight: height,
            screenFrame: screenFrame
        )
    }

    /// Builds the starting frame for the launch animation around the source UI
    /// element that initiated the permission flow.
    private func launchSourceFrame(for sourceFrameInScreen: CGRect) -> CGRect {
        let launchSize = CGSize(
            width: max(sourceFrameInScreen.width, frame.width * minimumLaunchScale),
            height: max(sourceFrameInScreen.height, frame.height * minimumLaunchScale)
        )
        let center = CGPoint(x: sourceFrameInScreen.midX, y: sourceFrameInScreen.midY)
        return CGRect(
            x: center.x - (launchSize.width * 0.5),
            y: center.y - (launchSize.height * 0.5),
            width: launchSize.width,
            height: launchSize.height
        )
    }

    /// Measures the SwiftUI content at a specific width so the panel height can
    /// fit its dynamic contents before being positioned or animated.
    private func measuredPanelHeight(for width: CGFloat) -> CGFloat {
        sizingView.setFrameSize(NSSize(width: width, height: sizingHeightLimit))
        sizingView.layoutSubtreeIfNeeded()
        return FloatingDropPanelFrameResolver.clampedPanelHeight(sizingView.fittingSize.height)
    }

    /// Advances the current launch animation frame-by-frame until the panel
    /// reaches its destination under the System Settings window.
    private func stepLaunchAnimation() {
        let elapsed = max(0, CACurrentMediaTime() - launchStartTime)
        if elapsed >= animationDuration {
            isAnimatingLaunch = false
            stopLaunchAnimation()
            alphaValue = 1
            setFrame(launchToFrame, display: true)
            return
        }

        let progress = springProgress(at: elapsed)
        alphaValue = initialAlpha + ((1 - initialAlpha) * progress)
        setFrame(curvedFrame(from: launchFromFrame, to: launchToFrame, progress: progress), display: true)
    }

    /// Stops and clears the timer that drives the launch animation.
    private func stopLaunchAnimation() {
        launchTimer?.invalidate()
        launchTimer = nil
    }

    /// Produces a smooth eased progress value for the launch motion so the
    /// panel accelerates and settles without a harsh linear stop.
    private func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / animationResponse
        let progress = 1 - exp(-omega * elapsed) * (1 + (omega * elapsed))
        return min(max(progress, 0), 1)
    }

    /// Interpolates the animated frame along a quadratic Bezier path between
    /// the source and destination rectangles for a softer "fly in" effect.
    private func curvedFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        // A quadratic Bezier curve gives the panel a softer "fly to target"
        // motion than a straight linear interpolation.
        let size = CGSize(
            width: from.width + ((to.width - from.width) * progress),
            height: from.height + ((to.height - from.height) * progress)
        )

        let startCenter = CGPoint(x: from.midX, y: from.midY)
        let endCenter = CGPoint(x: to.midX, y: to.midY)
        let midpoint = CGPoint(
            x: (startCenter.x + endCenter.x) * 0.5,
            y: max(startCenter.y, endCenter.y)
        )
        let distance = hypot(endCenter.x - startCenter.x, endCenter.y - startCenter.y)
        let lift = min(140, max(44, distance * 0.18))
        let controlPoint = CGPoint(x: midpoint.x, y: midpoint.y + lift)
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * startCenter.x) + (2 * inverse * progress * controlPoint.x) + (progress * progress * endCenter.x),
            y: (inverse * inverse * startCenter.y) + (2 * inverse * progress * controlPoint.y) + (progress * progress * endCenter.y)
        )

        return CGRect(
            x: center.x - (size.width * 0.5),
            y: center.y - (size.height * 0.5),
            width: size.width,
            height: size.height
        )
    }

    private static func makePanelView(
        controller: PermissionFlowController,
        localeIdentifier: String?
    ) -> AnyView {
        let view = PermissionFlowPanelView(controller: controller)
        guard let localeIdentifier else { return AnyView(view) }
        return AnyView(view.environment(\.locale, .init(identifier: localeIdentifier)))
    }
}

@available(macOS 13.0, *)
struct FloatingDropPanelFrameResolver {
    /// System Settings has a leading sidebar. The helper belongs in the
    /// trailing content area, but still inside the tracked Settings window.
    private static let sidebarWidth: CGFloat = 230
    private static let inset: CGFloat = 12
    private static let minimumWidth: CGFloat = 240
    private static let minimumHeight: CGFloat = 96
    private static let maximumHeight: CGFloat = 220

    static func targetWidth(for settingsFrame: CGRect, screenFrame: CGRect) -> CGFloat {
        let availableContentWidth = max(
            minimumWidth,
            settingsFrame.width - sidebarWidth - inset
        )
        return min(availableContentWidth, screenFrame.width - (inset * 2))
    }

    static func targetFrame(
        for settingsFrame: CGRect,
        measuredPanelHeight: CGFloat,
        screenFrame: CGRect
    ) -> CGRect {
        let width = targetWidth(for: settingsFrame, screenFrame: screenFrame)
        let availableHeight = min(maximumHeight, max(minimumHeight, settingsFrame.height - (inset * 2)))
        let height = min(clampedPanelHeight(measuredPanelHeight), availableHeight)

        let minX = max(settingsFrame.minX + sidebarWidth, screenFrame.minX + inset)
        let maxX = min(settingsFrame.maxX - inset, screenFrame.maxX - inset) - width
        let x = max(minX, min(minX, maxX))

        let minY = max(settingsFrame.minY + inset, screenFrame.minY + inset)
        let maxY = min(settingsFrame.maxY - inset, screenFrame.maxY - inset) - height
        let y = max(minY, min(minY, maxY))

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func clampedPanelHeight(_ measuredHeight: CGFloat) -> CGFloat {
        min(max(minimumHeight, measuredHeight), maximumHeight)
    }
}

@available(macOS 13.0, *)
extension FloatingDropPanel: FloatingDropPaneling {
    func bringToFront() {
        orderFrontRegardless()
    }
}
#endif
