import Foundation
import SwiftUI

@Observable
final class PaperCanvasPane: Identifiable {
    let pane: PaneState
    var frame: CGRect

    var id: PaneID { pane.id }

    init(pane: PaneState, frame: CGRect) {
        self.pane = pane
        self.frame = frame.integral
    }
}

@Observable
final class PaperCanvasState {
    var panes: [PaperCanvasPane]
    var viewportOrigin: CGPoint
    var viewportSize: CGSize
    var canvasBounds: CGRect
    let paneGap: CGFloat

    init(
        panes: [PaperCanvasPane],
        viewportOrigin: CGPoint = .zero,
        viewportSize: CGSize = .zero,
        paneGap: CGFloat = 16
    ) {
        self.panes = panes
        self.viewportOrigin = viewportOrigin
        self.viewportSize = viewportSize
        self.paneGap = paneGap
        self.canvasBounds = .zero
        recomputeCanvasBounds()
        clampViewportOrigin()
    }

    func pane(_ paneId: PaneID) -> PaperCanvasPane? {
        panes.first { $0.pane.id == paneId }
    }

    var allPanes: [PaneState] {
        panes.map(\.pane)
    }

    var allPaneIds: [PaneID] {
        panes.map(\.pane.id)
    }

    func layoutSnapshot(focusedPaneId: PaneID?) -> PaperCanvasLayoutSnapshot {
        PaperCanvasLayoutSnapshot(
            panes: panes.map { PaperCanvasPaneSnapshot(paneId: $0.pane.id, frame: $0.frame) },
            viewportOrigin: viewportOrigin,
            canvasBounds: canvasBounds,
            focusedPaneId: focusedPaneId
        )
    }

    @discardableResult
    func addPane(_ pane: PaneState, frame: CGRect) -> PaperCanvasPane {
        let placement = PaperCanvasPane(pane: pane, frame: frame)
        panes.append(placement)
        recomputeCanvasBounds()
        return placement
    }

    @discardableResult
    func removePane(_ paneId: PaneID) -> PaperCanvasPane? {
        guard let index = panes.firstIndex(where: { $0.pane.id == paneId }) else { return nil }
        let removed = panes.remove(at: index)
        recomputeCanvasBounds()
        return removed
    }

    func updateViewportSize(_ size: CGSize) {
        viewportSize = size
        recomputeCanvasBounds()
        clampViewportOrigin()
    }

    func reveal(_ frame: CGRect, margin: CGFloat = 32) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        var nextOrigin = viewportOrigin
        if frame.minX < viewportOrigin.x + margin {
            nextOrigin.x = frame.minX - margin
        } else if frame.maxX > viewportOrigin.x + viewportSize.width - margin {
            nextOrigin.x = frame.maxX - viewportSize.width + margin
        }

        if frame.minY < viewportOrigin.y + margin {
            nextOrigin.y = frame.minY - margin
        } else if frame.maxY > viewportOrigin.y + viewportSize.height - margin {
            nextOrigin.y = frame.maxY - viewportSize.height + margin
        }

        viewportOrigin = nextOrigin
        clampViewportOrigin()
    }

    func centerViewport(on frame: CGRect) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        viewportOrigin = CGPoint(
            x: frame.midX - viewportSize.width / 2,
            y: frame.midY - viewportSize.height / 2
        )
        clampViewportOrigin()
    }

    func panViewport(by delta: CGSize) {
        viewportOrigin.x += delta.width
        viewportOrigin.y += delta.height
        clampViewportOrigin()
    }

    func recomputeCanvasBounds() {
        let union = panes.reduce(into: CGRect.null) { partial, placement in
            partial = partial.union(placement.frame)
        }

        let minimumBounds = CGRect(origin: .zero, size: viewportSize)
        canvasBounds = union.isNull ? minimumBounds : union.union(minimumBounds)
    }

    func clampViewportOrigin() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        let minX = canvasBounds.minX
        let maxX = max(canvasBounds.minX, canvasBounds.maxX - viewportSize.width)
        let minY = canvasBounds.minY
        let maxY = max(canvasBounds.minY, canvasBounds.maxY - viewportSize.height)

        viewportOrigin.x = min(max(viewportOrigin.x, minX), maxX)
        viewportOrigin.y = min(max(viewportOrigin.y, minY), maxY)
    }

    func setViewportOrigin(_ origin: CGPoint) {
        viewportOrigin = origin
        clampViewportOrigin()
    }

    func applyLayout(
        paneFrames: [PaneID: CGRect],
        viewportOrigin: CGPoint?,
        focusedPaneId _: PaneID?
    ) {
        for placement in panes {
            guard let frame = paneFrames[placement.pane.id] else { continue }
            placement.frame = frame.integral
        }

        recomputeCanvasBounds()
        if let viewportOrigin {
            setViewportOrigin(viewportOrigin)
        } else {
            clampViewportOrigin()
        }
    }

    @discardableResult
    func resizePane(
        _ paneId: PaneID,
        direction: NavigationDirection,
        amount: CGFloat,
        minimumSize: CGSize
    ) -> CGRect? {
        guard amount > 0,
              let target = pane(paneId) else {
            return nil
        }

        var newFrame = target.frame
        switch direction {
        case .left:
            newFrame.origin.x -= amount
            newFrame.size.width += amount
        case .right:
            newFrame.size.width += amount
        case .up:
            newFrame.origin.y -= amount
            newFrame.size.height += amount
        case .down:
            newFrame.size.height += amount
        }

        newFrame.size.width = max(newFrame.size.width, minimumSize.width)
        newFrame.size.height = max(newFrame.size.height, minimumSize.height)
        target.frame = newFrame.integral

        switch direction {
        case .left:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .horizontal,
                insertFirst: true,
                delta: amount,
                excluding: paneId
            )
        case .right:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .horizontal,
                insertFirst: false,
                delta: amount,
                excluding: paneId
            )
        case .up:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .vertical,
                insertFirst: true,
                delta: amount,
                excluding: paneId
            )
        case .down:
            shiftCollisions(
                startingFrames: [target.frame],
                orientation: .vertical,
                insertFirst: false,
                delta: amount,
                excluding: paneId
            )
        }

        recomputeCanvasBounds()
        reveal(target.frame)
        return target.frame
    }

    func resolvedSplitFrame(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        let translated = adjacentFrame(for: targetFrame, orientation: orientation, insertFirst: insertFirst)
        return resolveCollisions(for: translated, orientation: orientation, insertFirst: insertFirst)
    }

    private func adjacentFrame(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            return CGRect(
                x: insertFirst ? targetFrame.minX - targetFrame.width - paneGap : targetFrame.maxX + paneGap,
                y: targetFrame.minY,
                width: targetFrame.width,
                height: targetFrame.height
            )
        case .vertical:
            return CGRect(
                x: targetFrame.minX,
                y: insertFirst ? targetFrame.minY - targetFrame.height - paneGap : targetFrame.maxY + paneGap,
                width: targetFrame.width,
                height: targetFrame.height
            )
        }
    }

    private func resolveCollisions(
        for proposedFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        let shiftDistance = orientation == .horizontal
            ? proposedFrame.width + paneGap
            : proposedFrame.height + paneGap
        shiftCollisions(
            startingFrames: [proposedFrame],
            orientation: orientation,
            insertFirst: insertFirst,
            delta: shiftDistance
        )
        recomputeCanvasBounds()
        return proposedFrame.integral
    }

    private func shiftCollisions(
        startingFrames: [CGRect],
        orientation: SplitOrientation,
        insertFirst: Bool,
        delta: CGFloat,
        excluding excludedPaneId: PaneID? = nil
    ) {
        let signedDelta = delta * (insertFirst ? -1 : 1)
        let offset = orientation == .horizontal
            ? CGSize(width: signedDelta, height: 0)
            : CGSize(width: 0, height: signedDelta)

        var queue = startingFrames
        var shiftedPaneIds = Set<PaneID>()
        if let excludedPaneId {
            shiftedPaneIds.insert(excludedPaneId)
        }

        while let collisionFrame = queue.popLast() {
            let overlapping = panes.filter { placement in
                if shiftedPaneIds.contains(placement.pane.id) {
                    return false
                }

                switch orientation {
                case .horizontal:
                    let overlapsLane = placement.frame.maxY > collisionFrame.minY && placement.frame.minY < collisionFrame.maxY
                    let isInTravelDirection = insertFirst
                        ? placement.frame.minX <= collisionFrame.maxX
                        : placement.frame.maxX >= collisionFrame.minX
                    return overlapsLane
                        && isInTravelDirection
                        && placement.frame.intersects(collisionFrame.insetBy(dx: -paneGap / 2, dy: 0))
                case .vertical:
                    let overlapsLane = placement.frame.maxX > collisionFrame.minX && placement.frame.minX < collisionFrame.maxX
                    let isInTravelDirection = insertFirst
                        ? placement.frame.minY <= collisionFrame.maxY
                        : placement.frame.maxY >= collisionFrame.minY
                    return overlapsLane
                        && isInTravelDirection
                        && placement.frame.intersects(collisionFrame.insetBy(dx: 0, dy: -paneGap / 2))
                }
            }

            guard !overlapping.isEmpty else { continue }
            for placement in overlapping {
                shiftedPaneIds.insert(placement.pane.id)
                placement.frame = placement.frame.offsetBy(dx: offset.width, dy: offset.height).integral
                queue.append(placement.frame)
            }
        }
    }
}
