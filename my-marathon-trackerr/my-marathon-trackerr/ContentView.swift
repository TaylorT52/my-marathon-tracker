import CoreLocation
import FirebaseFirestore
import MapKit
import SwiftUI

private enum AppTheme {
    static let ink = Color(red: 0.08, green: 0.10, blue: 0.16)
    static let muted = Color(red: 0.39, green: 0.42, blue: 0.50)
    static let orange = Color(red: 1.00, green: 0.35, blue: 0.12)
    static let mint = Color(red: 0.18, green: 0.75, blue: 0.55)
    static let canvas = Color(red: 0.96, green: 0.96, blue: 0.94)
}

struct RaceUpdate: Identifiable, Equatable {
    let id: String
    let message: String
    let sentAt: Date
    let mile: Double

    init(id: String = UUID().uuidString, message: String, sentAt: Date, mile: Double) {
        self.id = id
        self.message = message
        self.sentAt = sentAt
        self.mile = mile
    }
}

enum RaceDistancePreset: String, CaseIterable, Identifiable {
    case fiveK
    case tenK
    case fifteenK
    case tenMiles
    case halfMarathon
    case marathon
    case fiftyK
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .fiveK: "5K"
        case .tenK: "10K"
        case .fifteenK: "15K"
        case .tenMiles: "10 miles"
        case .halfMarathon: "Half marathon"
        case .marathon: "Marathon"
        case .fiftyK: "50K"
        case .custom: "Custom"
        }
    }

    var miles: Double? {
        switch self {
        case .fiveK: 3.10686
        case .tenK: 6.21371
        case .fifteenK: 9.32057
        case .tenMiles: 10
        case .halfMarathon: 13.1094
        case .marathon: 26.2188
        case .fiftyK: 31.0686
        case .custom: nil
        }
    }
}

enum RaceMath {
    static func pace(seconds: TimeInterval, miles: Double) -> TimeInterval {
        guard miles > 0 else { return 0 }
        return seconds / miles
    }

    static func estimatedFinish(
        start: Date,
        elapsedSeconds: TimeInterval,
        distanceMiles: Double,
        targetDistanceMiles: Double
    ) -> Date? {
        guard distanceMiles > 0, targetDistanceMiles > 0 else { return nil }
        return start.addingTimeInterval(
            pace(seconds: elapsedSeconds, miles: distanceMiles) * targetDistanceMiles
        )
    }

    static func paceText(_ secondsPerMile: TimeInterval) -> String {
        guard secondsPerMile > 0, secondsPerMile.isFinite else { return "—" }
        let rounded = Int(secondsPerMile.rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}

@MainActor
final class RaceViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isRunnerMode = false
    @Published var isTracking = false
    @Published var runnerName = "Taylor"
    @Published var raceName = "Sunday Run"
    @Published var bibNumber = "2147"
    @Published var shareCode = "TAYLOR26"
    @Published var goalTime = 4.0
    @Published var distancePreset = RaceDistancePreset.marathon
    @Published var customDistanceMiles = 26.2
    @Published var distanceMiles = 18.4
    @Published var elapsedSeconds: TimeInterval = 2 * 3600 + 48 * 60 + 19
    @Published var lastUpdated = Date().addingTimeInterval(-18)
    @Published var runnerCoordinate = CLLocationCoordinate2D(latitude: 37.7829, longitude: -122.4429)
    @Published var updates: [RaceUpdate] = [
        RaceUpdate(message: "Feeling strong! Just passed the halfway mark 🏃", sentAt: Date().addingTimeInterval(-31 * 60), mile: 13.2),
        RaceUpdate(message: "Settled into my pace. See you all at the finish!", sentAt: Date().addingTimeInterval(-96 * 60), mile: 6.4)
    ]
    @Published var locationStatus = "Location is off"
    @Published private(set) var hasLiveLocation = false

    private(set) var connectedRaceId: String?
    private(set) var isConnectedRace = false
    private(set) var isOwner = false
    private var connectedTargetDistance: Double?

    let course: [CLLocationCoordinate2D] = [
        .init(latitude: 37.8078, longitude: -122.4183),
        .init(latitude: 37.8010, longitude: -122.4284),
        .init(latitude: 37.7961, longitude: -122.4372),
        .init(latitude: 37.7881, longitude: -122.4482),
        .init(latitude: 37.7787, longitude: -122.4521),
        .init(latitude: 37.7694, longitude: -122.4475),
        .init(latitude: 37.7598, longitude: -122.4355),
        .init(latitude: 37.7528, longitude: -122.4200),
        .init(latitude: 37.7594, longitude: -122.4067)
    ]

    private let locationManager = CLLocationManager()
    private var previousLocation: CLLocation?
    private var trackingStart: Date?
    private var elapsedAtStart: TimeInterval = 0
    private var wantsTracking = false
    private var hasStartedRealRace = false
    private var stateListener: ListenerRegistration?
    private var updatesListener: ListenerRegistration?
    private var publishTimer: Timer?
    private var lastPublishedAt: Date?

    override init() {
        super.init()
        configureLocationManager()
        updateAuthorizationLabel(locationManager.authorizationStatus)
    }

    init(connectedRace: ConnectedRace) {
        super.init()
        connectedRaceId = connectedRace.id
        isConnectedRace = true
        isOwner = connectedRace.isOwner
        connectedTargetDistance = connectedRace.targetDistanceMiles
        runnerName = connectedRace.runnerName
        raceName = connectedRace.raceName
        customDistanceMiles = connectedRace.targetDistanceMiles
        distancePreset = .custom
        distanceMiles = 0
        elapsedSeconds = 0
        updates = []
        isRunnerMode = connectedRace.isOwner
        locationStatus = connectedRace.isOwner ? "Ready to start live GPS" : "Waiting for the runner"
        configureLocationManager()
        updateAuthorizationLabel(locationManager.authorizationStatus)
        startLiveListeners()
    }

    deinit {
        stateListener?.remove()
        updatesListener?.remove()
        publishTimer?.invalidate()
    }

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 8
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    var paceSeconds: TimeInterval {
        RaceMath.pace(seconds: elapsedSeconds, miles: distanceMiles)
    }

    var estimatedFinish: Date {
        RaceMath.estimatedFinish(
            start: Date().addingTimeInterval(-elapsedSeconds),
            elapsedSeconds: elapsedSeconds,
            distanceMiles: distanceMiles,
            targetDistanceMiles: targetDistanceMiles
        ) ?? Calendar.current.date(byAdding: .hour, value: 4, to: Date())!
    }

    var estimatedFinishText: String {
        guard let estimate = RaceMath.estimatedFinish(
            start: Date().addingTimeInterval(-elapsedSeconds),
            elapsedSeconds: elapsedSeconds,
            distanceMiles: distanceMiles,
            targetDistanceMiles: targetDistanceMiles
        ) else {
            return "—"
        }
        return estimate.formatted(date: .omitted, time: .shortened)
    }

    var targetDistanceMiles: Double {
        let distance = connectedTargetDistance ?? distancePreset.miles ?? customDistanceMiles
        guard distance.isFinite, distance > 0 else { return 0.1 }
        return distance
    }

    var targetDistanceText: String {
        if let connectedTargetDistance {
            return "\(connectedTargetDistance.formatted(.number.precision(.fractionLength(0...2)))) MI"
        }
        if distancePreset == .custom {
            return "\(customDistanceMiles.formatted(.number.precision(.fractionLength(0...2)))) MI"
        }
        return distancePreset.title.uppercased()
    }

    var progress: Double {
        guard distanceMiles.isFinite else { return 0 }
        return min(max(distanceMiles / targetDistanceMiles, 0), 1)
    }

    var completedCourse: [CLLocationCoordinate2D] {
        let count = max(2, Int(Double(course.count) * progress.rounded(.up)))
        return Array(course.prefix(min(count, course.count)))
    }

    func toggleTracking() {
        guard !isConnectedRace || isOwner else { return }
        if isTracking {
            locationManager.stopUpdatingLocation()
            publishTimer?.invalidate()
            publishTimer = nil
            wantsTracking = false
            isTracking = false
            locationStatus = "Tracking paused"
            Task {
                await publishCurrentState(force: true)
                await updateRaceStatus("paused")
            }
            return
        }

        wantsTracking = true
        isRunnerMode = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginTracking()
        default:
            locationStatus = "Allow location access in Settings"
        }
    }

    func sendUpdate(_ message: String) {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let connectedRaceId, isOwner {
            Task {
                do {
                    try await Firestore.firestore()
                        .collection("races")
                        .document(connectedRaceId)
                        .collection("updates")
                        .addDocument(data: [
                            "message": cleaned,
                            "mile": distanceMiles,
                            "sentAt": FieldValue.serverTimestamp()
                        ])
                } catch {
                    locationStatus = "Update failed: \(error.localizedDescription)"
                }
            }
        } else {
            updates.insert(RaceUpdate(message: cleaned, sentAt: Date(), mile: distanceMiles), at: 0)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.handleLocation(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.locationStatus = message
        }
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        updateAuthorizationLabel(status)
        if wantsTracking && (status == .authorizedAlways || status == .authorizedWhenInUse) {
            beginTracking()
        }
    }

    private func handleLocation(_ latest: CLLocation) {
        guard latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy < 75 else { return }

        if let previousLocation, latest.timestamp.timeIntervalSince(previousLocation.timestamp) < 90 {
            let meters = latest.distance(from: previousLocation)
            if meters > 2, meters < 500 {
                distanceMiles += meters / 1609.344
            }
        }
        previousLocation = latest
        runnerCoordinate = latest.coordinate
        hasLiveLocation = true
        lastUpdated = latest.timestamp
        if let trackingStart {
            elapsedSeconds = elapsedAtStart + Date().timeIntervalSince(trackingStart)
        }
        Task { await publishCurrentState(force: false) }
    }

    private func beginTracking() {
        if !hasStartedRealRace {
            distanceMiles = 0
            elapsedSeconds = 0
            updates = []
            hasStartedRealRace = true
        }
        trackingStart = Date()
        elapsedAtStart = elapsedSeconds
        previousLocation = nil
        configureBackgroundTrackingIfAvailable()
        locationManager.startUpdatingLocation()
        isTracking = true
        locationStatus = "Live GPS is on"
        startPublishTimer()
        Task { await updateRaceStatus("live") }
    }

    private func startPublishTimer() {
        publishTimer?.invalidate()
        publishTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                if let trackingStart = self.trackingStart {
                    self.elapsedSeconds = self.elapsedAtStart + Date().timeIntervalSince(trackingStart)
                }
                await self.publishCurrentState(force: true)
            }
        }
    }

    private func startLiveListeners() {
        guard let connectedRaceId else { return }
        let raceRef = Firestore.firestore().collection("races").document(connectedRaceId)

        stateListener = raceRef.collection("state").document("latest")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.locationStatus = "Live sync error: \(error.localizedDescription)"
                        return
                    }
                    guard let data = snapshot?.data(),
                          let latitude = (data["latitude"] as? NSNumber)?.doubleValue,
                          let longitude = (data["longitude"] as? NSNumber)?.doubleValue,
                          let distance = (data["distanceMiles"] as? NSNumber)?.doubleValue,
                          let elapsed = (data["elapsedSeconds"] as? NSNumber)?.doubleValue,
                          CLLocationCoordinate2DIsValid(
                            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                          ) else {
                        return
                    }

                    self.runnerCoordinate = CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: longitude
                    )
                    self.distanceMiles = max(0, distance)
                    self.elapsedSeconds = max(0, elapsed)
                    self.lastUpdated = (data["recordedAt"] as? Timestamp)?.dateValue() ?? Date()
                    self.isTracking = data["isTracking"] as? Bool ?? false
                    self.hasLiveLocation = true
                    if !self.isOwner {
                        self.locationStatus = self.isTracking
                            ? "Receiving live GPS"
                            : "The runner’s tracking is paused"
                    }
                }
            }

        updatesListener = raceRef.collection("updates")
            .order(by: "sentAt", descending: true)
            .limit(to: 20)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.locationStatus = "Updates sync error: \(error.localizedDescription)"
                        return
                    }
                    self.updates = snapshot?.documents.compactMap { document in
                        let data = document.data()
                        guard let message = data["message"] as? String,
                              let mile = (data["mile"] as? NSNumber)?.doubleValue else {
                            return nil
                        }
                        return RaceUpdate(
                            id: document.documentID,
                            message: message,
                            sentAt: (data["sentAt"] as? Timestamp)?.dateValue() ?? Date(),
                            mile: mile
                        )
                    } ?? []
                }
            }
    }

    private func publishCurrentState(force: Bool) async {
        guard let connectedRaceId, isOwner, hasLiveLocation else { return }
        if !force, let lastPublishedAt,
           Date().timeIntervalSince(lastPublishedAt) < 10 {
            return
        }
        lastPublishedAt = Date()

        do {
            try await Firestore.firestore()
                .collection("races")
                .document(connectedRaceId)
                .collection("state")
                .document("latest")
                .setData([
                    "latitude": runnerCoordinate.latitude,
                    "longitude": runnerCoordinate.longitude,
                    "distanceMiles": distanceMiles,
                    "elapsedSeconds": elapsedSeconds,
                    "isTracking": isTracking,
                    "recordedAt": FieldValue.serverTimestamp()
                ])
            locationStatus = isTracking ? "Live GPS synced" : "Tracking paused"
        } catch {
            locationStatus = "GPS sync failed: \(error.localizedDescription)"
        }
    }

    private func updateRaceStatus(_ status: String) async {
        guard let connectedRaceId, isOwner else { return }
        do {
            try await Firestore.firestore()
                .collection("races")
                .document(connectedRaceId)
                .updateData(["status": status])
        } catch {
            locationStatus = "Status sync failed: \(error.localizedDescription)"
        }
    }

    private func configureBackgroundTrackingIfAvailable() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let supportsBackgroundLocation = modes?.contains("location") == true
        locationManager.allowsBackgroundLocationUpdates = supportsBackgroundLocation
        locationManager.showsBackgroundLocationIndicator = supportsBackgroundLocation
    }

    private func updateAuthorizationLabel(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways: locationStatus = "Background location ready"
        case .authorizedWhenInUse: locationStatus = "Location ready"
        case .denied, .restricted: locationStatus = "Location permission needed"
        case .notDetermined: locationStatus = "Location is off"
        @unknown default: locationStatus = "Location unavailable"
        }
    }
}

struct ContentView: View {
    @StateObject private var race: RaceViewModel
    private let onExit: (() -> Void)?
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7805, longitude: -122.4300),
            span: MKCoordinateSpan(latitudeDelta: 0.068, longitudeDelta: 0.068)
        )
    )
    @State private var showComposer = false
    @State private var showSettings = false
    @State private var hasCenteredOnLiveLocation = false

    init() {
        _race = StateObject(wrappedValue: RaceViewModel())
        onExit = nil
    }

    init(connectedRace: ConnectedRace, onExit: @escaping () -> Void) {
        _race = StateObject(wrappedValue: RaceViewModel(connectedRace: connectedRace))
        self.onExit = onExit
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        raceHeader
                        liveMap
                        raceStats
                        courseProgress
                        updatesCard
                        raceDayActions
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandMark() }
                ToolbarItem(placement: .topBarTrailing) {
                    if let onExit {
                        Button("Exit", action: onExit)
                            .fontWeight(.semibold)
                    } else {
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .background(.white, in: Circle())
                        }
                        .foregroundStyle(AppTheme.ink)
                        .accessibilityLabel("Race settings")
                    }
                }
            }
            .sheet(isPresented: $showComposer) {
                UpdateComposer(race: race)
                    .presentationDetents([.height(360)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                RaceSettings(race: race)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .tint(AppTheme.orange)
        .onChange(of: race.lastUpdated) { _, _ in
            guard race.hasLiveLocation, !hasCenteredOnLiveLocation else { return }
            hasCenteredOnLiveLocation = true
            camera = .region(
                MKCoordinateRegion(
                    center: race.runnerCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                )
            )
        }
    }

    private var raceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(race.raceName.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.orange)
                    Text("\(race.runnerName) is on the move")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                }
                Spacer()
                if race.isConnectedRace {
                    Label(
                        race.isOwner ? "RUNNER" : "WATCHING",
                        systemImage: race.isOwner ? "figure.run" : "eye.fill"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("BIB")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.muted)
                        Text(race.bibNumber)
                            .font(.system(.title3, design: .monospaced, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                    }
                }
            }
            Text("Live race-day progress, shared with the people cheering loudest.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
        }
        .padding(.top, 6)
    }

    private var liveMap: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if !race.isConnectedRace {
                MapPolyline(coordinates: race.course)
                    .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: race.course)
                    .stroke(AppTheme.ink.opacity(0.28), style: StrokeStyle(lineWidth: 3, dash: [2, 7]))
                MapPolyline(coordinates: race.completedCourse)
                    .stroke(AppTheme.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

                Annotation("Start", coordinate: race.course.first!) {
                    CoursePin(symbol: "flag.fill", color: AppTheme.ink)
                }
                Annotation("Finish", coordinate: race.course.last!) {
                    CoursePin(symbol: "flag.checkered", color: AppTheme.mint)
                }
            }
            if race.hasLiveLocation || !race.isConnectedRace {
                Annotation(race.runnerName, coordinate: race.runnerCoordinate, anchor: .bottom) {
                    RunnerPin(name: race.runnerName)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 7) {
                Circle()
                    .fill(race.isTracking ? AppTheme.mint : AppTheme.orange)
                    .frame(width: 8, height: 8)
                Text(
                    race.isTracking
                        ? "LIVE GPS"
                        : (race.isConnectedRace ? "WAITING FOR GPS" : "DEMO LIVE")
                )
                    .font(.caption2.weight(.black))
                    .tracking(0.8)
                Text("· \(race.lastUpdated.formatted(.relative(presentation: .numeric)))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThickMaterial, in: Capsule())
            .padding(14)
        }
        .overlay {
            if race.isConnectedRace && !race.hasLiveLocation {
                VStack(spacing: 8) {
                    Image(systemName: "location.slash")
                        .font(.title2)
                    Text(race.isOwner ? "Start live tracking to share your location" : "Waiting for the runner to start")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AppTheme.muted)
                .padding(18)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                withAnimation {
                    camera = .region(
                        MKCoordinateRegion(
                            center: race.runnerCoordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                        )
                    )
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .foregroundStyle(AppTheme.ink)
            .padding(14)
            .accessibilityLabel("Center map on runner")
        }
    }

    private var raceStats: some View {
        HStack(spacing: 0) {
            Stat(value: RaceMath.paceText(race.paceSeconds), unit: "/MI", label: "CURRENT PACE")
            Divider().frame(height: 52)
            Stat(value: race.distanceMiles.formatted(.number.precision(.fractionLength(1))), unit: "MI", label: "DISTANCE")
            Divider().frame(height: 52)
            Stat(value: race.estimatedFinishText, unit: "", label: "EST. FINISH")
        }
        .padding(.vertical, 18)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var courseProgress: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Course progress", systemImage: "figure.run")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(Int(race.progress * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppTheme.orange)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.ink.opacity(0.09))
                    Capsule()
                        .fill(AppTheme.orange)
                        .frame(width: proxy.size.width * race.progress)
                }
            }
            .frame(height: 10)
            HStack {
                Text("START")
                Spacer()
                Text((race.targetDistanceMiles / 2).formatted(.number.precision(.fractionLength(0...1))))
                Spacer()
                Text("FINISH \(race.targetDistanceText)")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.muted)
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var updatesCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FROM \(race.runnerName.uppercased())")
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(AppTheme.orange)
                    Text("Race updates")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                }
                Spacer()
                if race.isRunnerMode {
                    Button { showComposer = true } label: {
                        Label("Update", systemImage: "plus")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(AppTheme.ink, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }

            ForEach(Array(race.updates.prefix(3).enumerated()), id: \.element.id) { index, update in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(AppTheme.orange.opacity(0.12))
                        Image(systemName: "quote.opening")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.orange)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(update.message)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.ink)
                        Text("Mile \(update.mile.formatted(.number.precision(.fractionLength(1))))  ·  \(update.sentAt.formatted(.relative(presentation: .numeric)))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }
                }
            }
            if race.updates.isEmpty {
                Text(race.isOwner ? "Post an update for everyone watching." : "No runner updates yet.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var raceDayActions: some View {
        VStack(spacing: 13) {
            if race.isRunnerMode {
                Button { race.toggleTracking() } label: {
                    Label(
                        race.isTracking ? "Pause live tracking" : "Start live tracking",
                        systemImage: race.isTracking ? "pause.fill" : "location.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(race.isTracking ? AppTheme.ink : AppTheme.orange, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                }
                Text(race.locationStatus)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            } else {
                ShareLink(item: "Follow \(race.runnerName) at https://runalong.app/race/\(race.shareCode.lowercased())") {
                    Label("Invite another cheerleader", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
            }
            Text("Location and finish time are estimates. GPS and course conditions can cause delays.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.muted)
                .padding(.horizontal)
        }
    }
}

private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "figure.run.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.orange)
            Text("RUNALONG")
                .font(.system(.subheadline, design: .rounded, weight: .black))
                .tracking(0.8)
                .foregroundStyle(AppTheme.ink)
        }
    }
}

private struct CoursePin: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

private struct RunnerPin: View {
    let name: String

    var body: some View {
        VStack(spacing: 3) {
            Text(name)
                .font(.caption2.weight(.black))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white, in: Capsule())
                .foregroundStyle(AppTheme.ink)
            Image(systemName: "figure.run")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(AppTheme.orange, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 4))
                .shadow(color: AppTheme.orange.opacity(0.35), radius: 10, y: 4)
        }
    }
}

private struct Stat: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppTheme.orange)
                }
            }
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(AppTheme.muted)
        }
        .foregroundStyle(AppTheme.ink)
        .frame(maxWidth: .infinity)
    }
}

private struct UpdateComposer: View {
    @ObservedObject var race: RaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    private let suggestions = [
        "Feeling strong! 💪",
        "A little tired, but moving!",
        "See you at the finish! 🏁"
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Everyone following this race will see your update.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
                TextField("How’s the race going?", text: $message, axis: .vertical)
                    .lineLimit(3...5)
                    .padding(14)
                    .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 15))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { message = suggestion }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(AppTheme.ink)
                        }
                    }
                }
                Spacer()
                Button {
                    race.sendUpdate(message)
                    dismiss()
                } label: {
                    Label("Send to followers", systemImage: "paperplane.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(message.isEmpty ? AppTheme.muted : AppTheme.orange, in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.white)
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
            .navigationTitle("Post an update")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct RaceSettings: View {
    @ObservedObject var race: RaceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("View") {
                    Toggle("I’m the runner", isOn: $race.isRunnerMode)
                    Text(race.isRunnerMode
                         ? "Runner mode enables GPS tracking and race updates."
                         : "Spectator mode shows the shared race dashboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Race details") {
                    TextField("Runner name", text: $race.runnerName)
                    TextField("Race name", text: $race.raceName)
                    TextField("Bib number", text: $race.bibNumber)
                    TextField("Share code", text: $race.shareCode)
                        .textInputAutocapitalization(.characters)
                    Picker("Distance", selection: $race.distancePreset) {
                        ForEach(RaceDistancePreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    if race.distancePreset == .custom {
                        HStack {
                            Text("Custom distance")
                            Spacer()
                            TextField("Miles", value: $race.customDistanceMiles, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("mi")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(
                        "Goal: \(race.goalTime.formatted(.number.precision(.fractionLength(1)))) hours",
                        value: $race.goalTime,
                        in: 2.5...8,
                        step: 0.25
                    )
                }
                Section("Connections") {
                    Label("Live GPS: \(race.locationStatus)", systemImage: "location.fill")
                    Label("Strava: optional after-race sync", systemImage: "figure.run")
                    Text("Strava does not provide a public live-location feed. RunAlong uses this phone’s GPS during the race.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Race setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
