import CoreGraphics
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspacePaperCanvasTests: XCTestCase {
    private let paperLayoutDefaultsKey = "cmuxPaperPaneLayout"

    private func withPaperCanvasEnabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: paperLayoutDefaultsKey)
        defaults.set(true, forKey: paperLayoutDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: paperLayoutDefaultsKey)
            } else {
                defaults.removeObject(forKey: paperLayoutDefaultsKey)
            }
        }
        try body()
    }

    private func sortedFrames(_ frames: [CGRect]) -> [CGRect] {
        frames.sorted { lhs, rhs in
            if abs(lhs.minX - rhs.minX) > 0.001 {
                return lhs.minX < rhs.minX
            }
            if abs(lhs.minY - rhs.minY) > 0.001 {
                return lhs.minY < rhs.minY
            }
            return lhs.width < rhs.width
        }
    }

    func testSessionSnapshotRoundTripPreservesPaperPaneFramesAndViewport() throws {
        try withPaperCanvasEnabled {
            let workspace = Workspace()
            guard let rootPanelId = workspace.focusedPanelId,
                  let rightPanel = workspace.newTerminalSplit(from: rootPanelId, orientation: .horizontal),
                  workspace.newTerminalSplit(from: rightPanel.id, orientation: .vertical) != nil,
                  let originalLayout = workspace.bonsplitController.paperCanvasLayout() else {
                XCTFail("Expected paper layout setup to succeed")
                return
            }

            let snapshot = workspace.sessionSnapshot(includeScrollback: false)

            let restoredWorkspace = Workspace()
            restoredWorkspace.restoreSessionSnapshot(snapshot)

            guard let restoredLayout = restoredWorkspace.bonsplitController.paperCanvasLayout() else {
                XCTFail("Expected restored paper layout")
                return
            }

            let originalFrames = sortedFrames(originalLayout.panes.map(\.frame))
            let restoredFrames = sortedFrames(restoredLayout.panes.map(\.frame))
            XCTAssertEqual(restoredFrames.count, originalFrames.count)

            for (original, restored) in zip(originalFrames, restoredFrames) {
                XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
                XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
                XCTAssertEqual(restored.width, original.width, accuracy: 0.001)
                XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
            }

            XCTAssertEqual(restoredLayout.viewportOrigin.x, originalLayout.viewportOrigin.x, accuracy: 0.001)
            XCTAssertEqual(restoredLayout.viewportOrigin.y, originalLayout.viewportOrigin.y, accuracy: 0.001)
        }
    }

    func testOpenBrowserSplitRightReusesTopRightPaneInPaperCanvas() throws {
        try withPaperCanvasEnabled {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace,
                  let leftPanelId = workspace.focusedPanelId,
                  let topRightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
                  workspace.newTerminalSplit(from: topRightPanel.id, orientation: .vertical) != nil,
                  let topRightPaneId = workspace.paneId(forPanelId: topRightPanel.id),
                  let url = URL(string: "https://example.com/paper-top-right") else {
                XCTFail("Expected paper split setup")
                return
            }

            let initialPaneCount = workspace.bonsplitController.allPaneIds.count

            guard let browserPanelId = manager.openBrowser(
                inWorkspace: workspace.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) else {
                XCTFail("Expected browser panel to be created")
                return
            }

            XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, initialPaneCount)
            XCTAssertEqual(workspace.paneId(forPanelId: browserPanelId), topRightPaneId)
        }
    }
}
