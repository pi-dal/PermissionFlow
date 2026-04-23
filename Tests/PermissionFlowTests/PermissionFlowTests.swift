import Foundation
import Testing
@testable import PermissionFlow
@testable import SystemSettingsKit

@Test
func paneURLsUseSecuritySettingsDeepLink() {
    #expect(
        PermissionFlowPane.fullDiskAccess.settingsURL.absoluteString ==
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )
}

@Test
func typedDisplaysAnchorBuildsDeepLink() {
    #expect(
        SystemSettingsDestination.displays(anchor: .resolutionSection).url.absoluteString ==
        "x-apple.systempreferences:com.apple.Displays-Settings.extension?resolutionSection"
    )
}

@Test
@MainActor
func controllerAcceptsOnlyUniqueAppBundles() {
    let controller = PermissionFlowController()
    let appURL = URL(fileURLWithPath: "/Applications/Test.app")

    controller.registerDroppedApp(appURL)
    controller.registerDroppedApp(appURL)
    controller.registerDroppedApp(URL(fileURLWithPath: "/tmp/not-an-app.txt"))

    #expect(controller.droppedApps == [appURL])
}

@Test
@MainActor
func authorizeUsesTrackedSettingsFrameBeforeShowingPanel() {
    let sourceFrame = CGRect(x: 24, y: 32, width: 32, height: 32)
    let settingsFrame = CGRect(x: 640, y: 280, width: 720, height: 840)
    let tracker = TestSettingsWindowTracker()
    tracker.frameToPublishDuringStart = settingsFrame
    let panel = TestFloatingDropPanel()
    let controller = PermissionFlowController(
        configuration: .init(),
        tracker: tracker,
        panelFactory: { _ in panel }
    )

    controller.authorize(
        pane: .accessibility,
        suggestedAppURLs: [URL(fileURLWithPath: "/Applications/Test.app")],
        sourceFrameInScreen: sourceFrame
    )

    #expect(tracker.startTrackingCalls == [false])
    #expect(panel.events == [.present(from: sourceFrame, to: settingsFrame)])
}

@Test
func floatingPanelTargetFrameStaysInsideSettingsWindow() {
    let settingsFrame = CGRect(x: 120, y: 180, width: 920, height: 680)
    let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    let frame = FloatingDropPanelFrameResolver.targetFrame(
        for: settingsFrame,
        measuredPanelHeight: 124,
        screenFrame: screenFrame
    )

    #expect(settingsFrame.contains(frame))
}

@MainActor
private final class TestSettingsWindowTracker: SettingsWindowTracking {
    var onFrameChange: ((CGRect) -> Void)?
    var onTrackingEnded: (() -> Void)?
    var currentFrame: CGRect?
    var frameToPublishDuringStart: CGRect?
    var startTrackingCalls: [Bool] = []

    func startTracking(promptIfNeeded: Bool) {
        startTrackingCalls.append(promptIfNeeded)
        if let frameToPublishDuringStart {
            currentFrame = frameToPublishDuringStart
        }
    }

    func stopTracking() {
        currentFrame = nil
    }
}

@MainActor
private final class TestFloatingDropPanel: FloatingDropPaneling {
    enum Event: Equatable {
        case center
        case show
        case showAt(CGRect)
        case present(from: CGRect, to: CGRect)
        case snap(CGRect)
        case bringToFront
        case close
        case updateLocaleIdentifier(String?)
        case setDraggingPassthrough(Bool)
    }

    private(set) var events: [Event] = []

    func center() {
        events.append(.center)
    }

    func show() {
        events.append(.show)
    }

    func show(at sourceFrameInScreen: CGRect) {
        events.append(.showAt(sourceFrameInScreen))
    }

    func present(from sourceFrameInScreen: CGRect, to settingsFrame: CGRect) {
        events.append(.present(from: sourceFrameInScreen, to: settingsFrame))
    }

    func snap(to settingsFrame: CGRect) {
        events.append(.snap(settingsFrame))
    }

    func bringToFront() {
        events.append(.bringToFront)
    }

    func close() {
        events.append(.close)
    }

    func updateLocaleIdentifier(_ localeIdentifier: String?) {
        events.append(.updateLocaleIdentifier(localeIdentifier))
    }

    func setDraggingPassthrough(_ isDragging: Bool) {
        events.append(.setDraggingPassthrough(isDragging))
    }
}
