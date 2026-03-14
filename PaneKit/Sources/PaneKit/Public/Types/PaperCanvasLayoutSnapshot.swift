import CoreGraphics
import Foundation

public struct PaperCanvasPaneSnapshot: Equatable, Sendable {
    public let paneId: PaneID
    public let frame: CGRect

    public init(paneId: PaneID, frame: CGRect) {
        self.paneId = paneId
        self.frame = frame.integral
    }
}

public struct PaperCanvasLayoutSnapshot: Equatable, Sendable {
    public let panes: [PaperCanvasPaneSnapshot]
    public let viewportOrigin: CGPoint
    public let canvasBounds: CGRect
    public let focusedPaneId: PaneID?

    public init(
        panes: [PaperCanvasPaneSnapshot],
        viewportOrigin: CGPoint,
        canvasBounds: CGRect? = nil,
        focusedPaneId: PaneID?
    ) {
        self.panes = panes
        self.viewportOrigin = viewportOrigin
        self.focusedPaneId = focusedPaneId

        if let canvasBounds {
            self.canvasBounds = canvasBounds.integral
        } else {
            let union = panes.reduce(into: CGRect.null) { partial, pane in
                partial = partial.union(pane.frame)
            }
            self.canvasBounds = (union.isNull ? .zero : union).integral
        }
    }
}
