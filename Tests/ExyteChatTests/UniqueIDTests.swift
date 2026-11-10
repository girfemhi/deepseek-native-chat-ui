import XCTest

@testable import ExyteChat

final class UniqueIDTests: XCTestCase {
    private struct Item: Identifiable {
        let id: String
    }

    func testEmptyCollectionHasUniqueIDs() {
        XCTAssertTrue([Item]().hasUniqueIDs())
    }

    func testLongCollectionOfDistinctIDsIsValid() {
        let items=(0..<3_000).map { Item(id:"message-\($0)") }
        XCTAssertTrue(items.hasUniqueIDs())
    }

    func testAdjacentDuplicateIDsAreRejected() {
        let items=[Item(id:"one"),Item(id:"duplicate"),Item(id:"duplicate")]
        XCTAssertFalse(items.hasUniqueIDs())
    }

    func testFirstAndLastDuplicateIDsAreRejected() {
        let items=[Item(id:"same"),Item(id:"middle-1"),Item(id:"middle-2"),Item(id:"same")]
        XCTAssertFalse(items.hasUniqueIDs())
    }
}
