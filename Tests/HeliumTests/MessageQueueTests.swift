import XCTest
@testable import helium_terminal

final class MessageQueueTests: XCTestCase {
    private typealias S = MessageQueue.State

    func testSendsOnlyToAnIdleAgent() {
        XCTAssertNil(MessageQueue.hold(S(agent: true, knownIdle: true)))
        XCTAssertNil(MessageQueue.hold(S(agent: true, sawBusy: true)))
        XCTAssertNotNil(MessageQueue.hold(S(agent: false, sawBusy: true, knownIdle: true))) // a shell
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, hung: true, knownIdle: true)))
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, typing: true, knownIdle: true)))
        // The agent exited and another started in the pane: its startup isn't the turn these waited for.
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, replaced: true, sawBusy: true, knownIdle: true)))
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, editing: true, knownIdle: true)))
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, busy: true, sawBusy: true)))
    }

    func testNeverTypesIntoAPermissionPrompt() {
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, blocked: true, sawBusy: true, knownIdle: true)))
    }

    func testOneMessagePerTurn() {
        // Just sent: the idle report may predate the message, so the next one waits for a turn.
        XCTAssertNotNil(MessageQueue.hold(S(agent: true, knownIdle: true, sent: true)))
        XCTAssertNil(MessageQueue.hold(S(agent: true, sawBusy: true, knownIdle: true)))
    }

    func testAncestry() {
        let tree = ProcessTree()
        XCTAssertTrue(tree.isAncestor(getppid(), of: getpid()))
        XCTAssertTrue(tree.isAncestor(getpid(), of: getpid()))
        XCTAssertFalse(tree.isAncestor(getpid(), of: getppid()))
        // An agent in the foreground gets the queue; one suspended under its parent (here, the test runner) doesn't.
        XCTAssertTrue(Agents.isForeground(getpid(), foreground: getpid(), tree: tree))
        XCTAssertFalse(Agents.isForeground(getpid(), foreground: getppid(), tree: tree))
    }

    func testAgentWithoutAnIdleReportWaitsForATurn() {
        XCTAssertNotNil(MessageQueue.hold(S(agent: true))) // Codex queued while idle
    }
}
