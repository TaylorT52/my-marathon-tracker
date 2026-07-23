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
                .fieldStyle()
            SecureField("Password", text: $password)
                .textContentType(.password)
                .fieldStyle()

            Button {
                Task { await store.signIn(email: email, password: password) }
            } label: {
                actionLabel("Sign in", symbol: "person.crop.circle.fill")
            }
            .disabled(store.isWorking || email.isEmpty || password.isEmpty)

            Button {
                Task { await store.createAccount(email: email, password: password) }
            } label: {
                Text("Create a new account")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isWorking || email.isEmpty || password.count < 6)

            Button("Forgot password?") {
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
                .fieldStyle()
            TextField("Race name", text: $raceName)
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
                    Text("mi").foregroundStyle(.secondary)
                }
                .fieldStyle()
            }

            Toggle(isOn: $isPrivateRace) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private race")
                        .fontWeight(.semibold)
                    Text("Viewers need an 8-character passcode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
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

private struct JoinFlow: View {
    @ObservedObject var store: FirebaseRaceStore
    @State private var passcode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join privately")
                .font(.title2.weight(.bold))
            Text("Enter the passcode the runner sent you. No account setup is needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("8-character passcode", text: $passcode)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: passcode) { _, value in
                    passcode = String(
                        value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                    )
                }
                .fieldStyle()

            Button {
                Task { await store.joinRace(passcode: passcode) }
            } label: {
                actionLabel("Watch this race", symbol: "eye.fill")
            }
            .disabled(store.isWorking || passcode.count != 8)

            if store.isWorking {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .portalCard()
    }
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
