import XCTest
@testable import my_marathon_trackerr

final class my_marathon_trackerrTests: XCTestCase {
    func testPaceCalculation() {
        let pace = RaceMath.pace(seconds: 3_600, miles: 6)
        XCTAssertEqual(pace, 600, accuracy: 0.001)
        XCTAssertEqual(RaceMath.paceText(pace), "10:00")
    }

    func testEstimatedFinishUsesCurrentAveragePace() {
        let start = Date(timeIntervalSince1970: 0)
        let finish = RaceMath.estimatedFinish(
            start: start,
            elapsedSeconds: 7_200,
            distanceMiles: 12,
            targetDistanceMiles: 26.2188
        )
        XCTAssertNotNil(finish)
        XCTAssertEqual(finish!.timeIntervalSince(start), 15_731.28, accuracy: 0.1)
    }

    func testZeroDistanceDoesNotProduceAnEstimate() {
        XCTAssertNil(
            RaceMath.estimatedFinish(
                start: Date(),
                elapsedSeconds: 100,
                distanceMiles: 0,
                targetDistanceMiles: 6.21371
            )
        )
    }

    func testFinishEstimateSupportsAnyDistance() {
        let start = Date(timeIntervalSince1970: 0)
        let finish = RaceMath.estimatedFinish(
            start: start,
            elapsedSeconds: 1_800,
            distanceMiles: 3,
            targetDistanceMiles: 10
        )
        XCTAssertEqual(finish!.timeIntervalSince(start), 6_000, accuracy: 0.1)
    }
}
