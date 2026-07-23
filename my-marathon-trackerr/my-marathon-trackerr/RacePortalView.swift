import SwiftUI
import UIKit

struct RacePortalView: View {
    @StateObject private var store = FirebaseRaceStore()
    @State private var mode = PortalMode.create

    var body: some View {
        Group {
            if let race = store.activeRace {
                ConnectedRaceView(race: race, store: store)
            } else {
                NavigationStack {
                    ZStack {
                        Color(red: 0.96, green: 0.96, blue: 0.94)
                            .ignoresSafeArea()
                        ScrollView {
                            VStack(spacing: 24) {
                                portalHeader
                                Picker("Action", selection: $mode) {
                                    ForEach(PortalMode.allCases) { item in
                                        Text(item.title).tag(item)
                                    }
                                }
                                .pickerStyle(.segmented)

                                if mode == .create {
                                    CreatorFlow(store: store)
                                } else {
                                    JoinFlow(store: store)
                                }
                            }
                            .padding(20)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
        }
        .alert(
            store.alertTitle,
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var portalHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.12))
            Text("RUNALONG")
                .font(.system(.title, design: .rounded, weight: .black))
                .tracking(1.2)
            Text("Share every mile with your people.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }
}

private enum PortalMode: String, CaseIterable, Identifiable {
    case create
    case join

    var id: Self { self }
    var title: String { self == .create ? "Create a race" : "Join a race" }
}

private struct CreatorFlow: View {
    @ObservedObject var store: FirebaseRaceStore
    @State private var email = ""
    @State private var password = ""
    @State private var runnerName = ""
    @State private var raceName = ""
    @State private var distancePreset = RaceDistancePreset.fiveK
    @State private var customDistance = 3.1
    @State private var isPrivateRace = true
    @FocusState private var focusedField: CreatorField?

    var body: some View {
        VStack(spacing: 18) {
            if store.isCreatorSignedIn {
                creatorCard
            } else {
                signInCard
            }
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Creator account")
                .font(.title2.weight(.bold))
            Text("Sign in so your race remains connected to you across devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .fieldStyle()
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .fieldStyle()

            Button {
                focusedField = nil
                Task { await store.signIn(email: email, password: password) }
            } label: {
                actionLabel("Sign in", symbol: "person.crop.circle.fill")
            }
            .disabled(store.isWorking || email.isEmpty || password.isEmpty)

            Button {
                focusedField = nil
                Task { await store.createAccount(email: email, password: password) }
            } label: {
                Text("Create a new account")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isWorking || email.isEmpty || password.count < 6)

            Button("Forgot password?") {
                focusedField = nil
                Task { await store.sendPasswordReset(email: email) }
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .disabled(store.isWorking || email.isEmpty)

            Text("Email/Password must be enabled in Firebase Authentication.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .portalCard()
    }

    private var creatorCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Create your race")
                        .font(.title2.weight(.bold))
                    Text(store.creatorEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign out") { store.signOut() }
                    .font(.caption.weight(.semibold))
            }

            TextField("Runner name", text: $runnerName)
                .textContentType(.name)
                .focused($focusedField, equals: .runnerName)
                .fieldStyle()
            TextField("Race name", text: $raceName)
                .focused($focusedField, equals: .raceName)
                .fieldStyle()

            Picker("Distance", selection: $distancePreset) {
                ForEach(RaceDistancePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)

            if distancePreset == .custom {
                HStack {
                    Text("Distance")
                    Spacer()
                    TextField("Miles", value: $customDistance, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focusedField, equals: .distance)
                    Text("mi").foregroundStyle(.secondary)
                }
                .fieldStyle()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Who can watch?")
                    .font(.subheadline.weight(.semibold))
                Picker("Race visibility", selection: $isPrivateRace) {
                    Text("Public").tag(false)
                    Text("Private").tag(true)
                }
                .pickerStyle(.segmented)
                Label(
                    isPrivateRace
                        ? "Only people with your 8-character passcode can find and watch this race."
                        : "Anyone using RunAlong can find and watch this race.",
                    systemImage: isPrivateRace ? "lock.fill" : "globe.americas.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                focusedField = nil
                Task {
                    await store.createRace(
                        raceName: raceName,
                        runnerName: runnerName,
                        targetDistanceMiles: distancePreset.miles ?? customDistance,
                        isPrivate: isPrivateRace
                    )
                }
            } label: {
                actionLabel("Create race", symbol: "flag.checkered")
            }
            .disabled(
                store.isWorking ||
                raceName.trimmingCharacters(in: .whitespaces).isEmpty ||
                runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            )

            if store.isWorking {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .portalCard()
    }
}

private enum CreatorField: Hashable {
    case email
    case password
    case runnerName
    case raceName
    case distance
}

private struct JoinFlow: View {
    @ObservedObject var store: FirebaseRaceStore
    @State private var joinMethod = JoinMethod.publicRaces
    @State private var passcode = ""
    @FocusState private var passcodeIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Watch a race")
                .font(.title2.weight(.bold))

            Picker("How to join", selection: $joinMethod) {
                ForEach(JoinMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)

            if joinMethod == .publicRaces {
                publicRaceList
            } else {
                privatePasscodeForm
            }

            if store.isWorking || store.isLoadingPublicRaces {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .portalCard()
        .task {
            if store.publicRaces.isEmpty {
                await store.loadPublicRaces()
            }
        }
    }

    private var publicRaceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Public races")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await store.loadPublicRaces() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh public races")
                .disabled(store.isLoadingPublicRaces)
            }

            if store.publicRaces.isEmpty && !store.isLoadingPublicRaces {
                ContentUnavailableView(
                    "No public races yet",
                    systemImage: "flag.checkered",
                    description: Text("Create the first one, or join a private race with a passcode.")
                )
            } else {
                ForEach(store.publicRaces) { race in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(race.raceName)
                                    .font(.headline)
                                Text("\(race.runnerName) · \(race.targetDistanceMiles.formatted(.number.precision(.fractionLength(0...2)))) miles")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(race.status == "live" ? "LIVE" : "UPCOMING")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(race.status == "live" ? .red : .secondary)
                        }

                        Button {
                            passcodeIsFocused = false
                            Task { await store.joinPublicRace(race) }
                        } label: {
                            Label("Watch", systemImage: "eye.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.08, green: 0.10, blue: 0.16))
                        .disabled(store.isWorking)
                    }
                    .padding(14)
                    .background(
                        Color(red: 0.95, green: 0.95, blue: 0.93),
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                }
            }
        }
    }

    private var privatePasscodeForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the passcode the runner sent you. No account setup is needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("8-character passcode", text: $passcode)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($passcodeIsFocused)
                .onChange(of: passcode) { _, value in
                    passcode = String(
                        value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                    )
                }
                .fieldStyle()

            Button {
                passcodeIsFocused = false
                Task { await store.joinRace(passcode: passcode) }
            } label: {
                actionLabel("Watch private race", symbol: "lock.open.fill")
            }
            .disabled(store.isWorking || passcode.count != 8)
        }
    }
}

private enum JoinMethod: String, CaseIterable, Identifiable {
    case publicRaces
    case passcode

    var id: Self { self }
    var title: String { self == .publicRaces ? "Public" : "Passcode" }
}

private struct ConnectedRaceView: View {
    let race: ConnectedRace
    @ObservedObject var store: FirebaseRaceStore
    @State private var showDashboard = false

    var body: some View {
        if showDashboard {
            ContentView()
        } else {
            ZStack {
                Color(red: 0.96, green: 0.96, blue: 0.94).ignoresSafeArea()
                VStack(spacing: 22) {
                    Image(systemName: race.isOwner ? "checkmark.seal.fill" : "eye.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Color(red: 0.18, green: 0.75, blue: 0.55))
                    VStack(spacing: 6) {
                        Text(race.isOwner ? "Race created" : "You’re in")
                            .font(.system(.largeTitle, design: .rounded, weight: .black))
                        Text(race.raceName)
                            .font(.title3.weight(.semibold))
                        Text("\(race.runnerName) · \(race.targetDistanceMiles.formatted(.number.precision(.fractionLength(0...2)))) miles")
                            .foregroundStyle(.secondary)
                    }

                    if let passcode = race.passcode {
                        VStack(spacing: 8) {
                            Text("PRIVATE VIEWER PASSCODE")
                                .font(.caption.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                            Text(passcode)
                                .font(.system(size: 34, weight: .black, design: .monospaced))
                                .tracking(4)
                            Button {
                                UIPasteboard.general.string = passcode
                            } label: {
                                Label("Copy passcode", systemImage: "doc.on.doc")
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(22)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))

                        ShareLink(item: "Follow \(race.runnerName)’s race in RunAlong with passcode \(passcode)") {
                            Label("Share invitation", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    } else if race.isOwner && !race.isPrivate {
                        VStack(spacing: 8) {
                            Label("PUBLIC RACE", systemImage: "globe.americas.fill")
                                .font(.caption.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                            Text("Anyone can find this race in the Public list.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(22)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))

                        ShareLink(item: "Watch \(race.runnerName) in “\(race.raceName)” under Public races in RunAlong.") {
                            Label("Share race", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        showDashboard = true
                    } label: {
                        actionLabel(
                            race.isOwner ? "Open runner dashboard" : "Open live race",
                            symbol: "arrow.right"
                        )
                    }
                    Button("Back") { store.leaveRace() }
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }
}

private func actionLabel(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(red: 0.08, green: 0.10, blue: 0.16), in: RoundedRectangle(cornerRadius: 15))
        .foregroundStyle(.white)
}

private extension View {
    func fieldStyle() -> some View {
        padding(13)
            .background(
                Color(red: 0.95, green: 0.95, blue: 0.93),
                in: RoundedRectangle(cornerRadius: 13)
            )
    }

    func portalCard() -> some View {
        padding(20)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
    }
}
