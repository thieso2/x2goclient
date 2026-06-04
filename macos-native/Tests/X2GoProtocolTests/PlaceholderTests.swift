import XCTest
@testable import X2GoProtocol

final class PlaceholderTests: XCTestCase {
    func testVersion() { XCTAssertEqual(X2GoProtocolInfo.version, 1) }
}
