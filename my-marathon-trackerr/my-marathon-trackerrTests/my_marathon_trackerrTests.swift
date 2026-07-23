import XCTest
@testable import my_marathon_trackerr

final class my_marathon_trackerrTests: XCTestCase {
    func testActiveRaceSessionRoundTripsWithoutStoringRaceSecrets() {
        let suiteName = "RaceSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RaceSessionStore(defaults: defaults)
        let session = ActiveRaceSession(raceId: "race-123", userId: "user-456")

        store.save(session)

        XCTAssertEqual(store.load(), session)
        let persistedText = String(
            data: defaults.data(forKey: "runalong.activeRaceSession")!,
            encoding: .utf8
        )
        XCTAssertFalse(persistedText?.localizedCaseInsensitiveContains("passcode") ?? true)
    }

    func testLeavingRaceClearsSavedSession() {
        let suiteName = "RaceSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RaceSessionStore(defaults: defaults)
        store.save(ActiveRaceSession(raceId: "race-123", userId: "user-456"))

        store.clear()

        XCTAssertNil(store.load())
    }

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

    func testRollingPaceUsesOnlyRecentMovement() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pace = RaceMath.rollingPace(
            segments: [
                PaceSegment(
                    distanceMeters: 1_000,
                    durationSeconds: 1_000,
                    endedAt: now.addingTimeInterval(-61)
                ),
                PaceSegment(
                    distanceMeters: 80.4672,
                    durationSeconds: 30,
                    endedAt: now.addingTimeInterval(-20)
                ),
                PaceSegment(
                    distanceMeters: 80.4672,
                    durationSeconds: 30,
                    endedAt: now
                )
            ],
            now: now
        )

        XCTAssertEqual(pace, 600, accuracy: 0.001)
        XCTAssertEqual(RaceMath.paceText(pace), "10:00")
    }

    func testRollingPaceWaitsForEnoughMovement() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pace = RaceMath.rollingPace(
            segments: [
                PaceSegment(distanceMeters: 10, durationSeconds: 10, endedAt: now)
            ],
            now: now
        )
        XCTAssertEqual(pace, 0)
    }

    func testEstimatedFinishUsesRollingPaceForRemainingDistance() {
        let start = Date(timeIntervalSince1970: 0)
        let finish = RaceMath.estimatedFinish(
            start: start,
            elapsedSeconds: 3_600,
            distanceMiles: 5,
            targetDistanceMiles: 10,
            currentPaceSeconds: 600
        )
        XCTAssertEqual(finish!.timeIntervalSince(start), 6_600, accuracy: 0.001)
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
