import XCTest

@testable import ExyteChat

@MainActor
final class PaginationStateTests: XCTestCase {
    func testOlderRequestStaysLockedUntilCompletionAndCanRetry() async {
        let state=PaginationState()

        XCTAssertTrue(state.beginOlder())
        XCTAssertTrue(state.olderInProgress)
        XCTAssertFalse(state.beginOlder(),"A live message update must not start the same page twice")
        XCTAssertTrue(state.olderInProgress)

        await state.completeOlder { }
        XCTAssertFalse(state.olderInProgress)
        XCTAssertFalse(state.beginOlder(),"Completion alone must not loop at the unchanged boundary")
        state.rearmOlder()
        XCTAssertTrue(state.beginOlder(),"Failure or an empty page must allow a later retry")
    }

    func testNewerRequestStaysLockedUntilCompletionAndCanRetry() async {
        let state=PaginationState()

        XCTAssertTrue(state.beginNewer())
        XCTAssertFalse(state.beginNewer())
        XCTAssertTrue(state.newerInProgress)

        await state.completeNewer { }
        XCTAssertFalse(state.newerInProgress)
        XCTAssertFalse(state.beginNewer())
        state.rearmNewer()
        XCTAssertTrue(state.beginNewer())
    }

    func testOlderAndNewerRequestsHaveIndependentLifecycles() {
        let state=PaginationState()
        XCTAssertTrue(state.beginOlder())
        XCTAssertTrue(state.beginNewer())
        state.rearmOlder();state.rearmNewer()
        XCTAssertFalse(state.beginOlder(),"Rearming cannot unlock an in-flight older request")
        XCTAssertFalse(state.beginNewer(),"Rearming cannot unlock an in-flight newer request")

        state.finishOlder()
        XCTAssertFalse(state.olderInProgress)
        XCTAssertTrue(state.newerInProgress)

        state.finishNewer()
        XCTAssertFalse(state.newerInProgress)
        state.rearmOlder();state.rearmNewer()
        XCTAssertTrue(state.beginOlder())
        XCTAssertTrue(state.beginNewer())
    }
}
