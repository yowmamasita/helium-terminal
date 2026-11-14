import AppKit
import XCTest
@testable import helium_terminal

final class SplitTests: XCTestCase {
    /// A pane split twice to the right: [A | [B | C]] must give three equal columns, not 1/2, 1/4, 1/4.
    func testNestedSameDirectionSplitsGetEqualPanes() {
        func split(_ views: [NSView], width: CGFloat) -> NSSplitView {
            let s = NSSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            s.isVertical = true
            s.dividerStyle = .thin
            views.forEach(s.addArrangedSubview)
            s.adjustSubviews()
            return s
        }
        let a = NSView(), b = NSView(), c = NSView()
        let outer = split([a, split([b, c], width: 150)], width: 302)
        Workspace.equalizeRun(outer)
        let pane = (302 - 2 * outer.dividerThickness) / 3
        for v in [a, b, c] { XCTAssertEqual(v.frame.width, pane, accuracy: 1) }
    }
}
