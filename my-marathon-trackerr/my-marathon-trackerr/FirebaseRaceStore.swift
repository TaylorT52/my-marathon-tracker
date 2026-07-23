import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Security

struct ConnectedRace: Identifiable, Equatable {
    let id: String
    let raceName: String
    let runnerName: String
    let targetDistanceMiles: Double
    let isPrivate: Bool
    let passcode: String?
    let isOwner: Bool
    let status: String
    let wasRestored: Bool
}

struct PublicRace: Identifiable, Equatable {
    let id: String
    let raceName: String
    let runnerName: String
    let targetDistanceMiles: Double
    let status: String
    let ownerId: String
}

struct MyRace: Identifiable, Equatable {
    let id: String
    let raceName: String
    let runnerName: String
    let targetDistanceMiles: Double
    let isPrivate: Bool
    let status: String
    let createdAt: Date
}

struct ActiveRaceSession: Codable, Equatable {
    let raceId: String
    let userId: String
}

final class RaceSessionStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "runalong.activeRaceSession") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ActiveRaceSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ActiveRaceSession.self, from: data)
    }

    func save(_ session: ActiveRaceSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
final class FirebaseRaceStore: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var activeRace: ConnectedRace?
    @Published private(set) var publicRaces: [PublicRace] = []
    @Published private(set) var myRaces: [MyRace] = []
    @Published private(set) var isLoadingPublicRaces = false
    @Published private(set) var isLoadingMyRaces = false
    @Published private(set) var isWorking = false
    @Published private(set) var isRestoringRace = false
    @Published private(set) var canRetryRaceRecovery = false
    @Published var alertTitle = "Something went wrong"
    @Published var errorMessage: String?

    private let auth = Auth.auth()
    private let database = Firestore.firestore()
    private let sessionStore: RaceSessionStore
    private var authHandle: AuthStateDidChangeListenerHandle?

    init(sessionStore: RaceSessionStore = RaceSessionStore()) {
        self.sessionStore = sessionStore
        user = auth.currentUser
        isRestoringRace = sessionStore.load() != nil && auth.currentUser != nil
        authHandle = auth.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                await self?.handleAuthChange(user)
            }
        }
    }

    deinit {
        if let authHandle {
            auth.removeStateDidChangeListener(authHandle)
        }
    }

    var isCreatorSignedIn: Bool {
        guard let user else { return false }
        return !user.isAnonymous
    }

    var creatorEmail: String {
        user?.email ?? ""
    }

    func createAccount(email: String, password: String) async {
        await perform {
            _ = try await self.auth.createUser(
                withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        }
    }

    func signIn(email: String, password: String) async {
        await perform {
            _ = try await self.auth.signIn(
                withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        }
    }

    func sendPasswordReset(email: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            errorMessage = "Enter your email address first."
            return
        }

        await perform {
            try await self.auth.sendPasswordReset(withEmail: trimmedEmail)
            self.alertTitle = "Check your email"
            self.errorMessage = "Password reset email sent. Check your inbox."
        }
    }

    func signOut() {
        do {
            sessionStore.clear()
            try auth.signOut()
            activeRace = nil
            myRaces = []
            canRetryRaceRecovery = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createRace(
        raceName: String,
        runnerName: String,
        targetDistanceMiles: Double,
        isPrivate: Bool
    ) async {
        await perform {
            guard let user = self.auth.currentUser, !user.isAnonymous else {
                throw RaceStoreError.creatorAccountRequired
            }

            let cleanRaceName = try self.validatedText(raceName, field: "Race name", limit: 80)
            let cleanRunnerName = try self.validatedText(runnerName, field: "Runner name", limit: 60)
            guard targetDistanceMiles.isFinite,
                  (0.1...500).contains(targetDistanceMiles) else {
                throw RaceStoreError.invalidDistance
            }

            let raceRef = self.database.collection("races").document()
            let batch = self.database.batch()
            let passcode = isPrivate ? try self.randomPasscode() : nil

            batch.setData([
                "ownerId": user.uid,
                "raceName": cleanRaceName,
                "runnerName": cleanRunnerName,
                "targetDistanceMiles": targetDistanceMiles,
                "isPrivate": isPrivate,
                "status": "setup",
                "createdAt": FieldValue.serverTimestamp()
            ], forDocument: raceRef)
            batch.setData([
                "role": "runner",
                "joinedAt": FieldValue.serverTimestamp()
            ], forDocument: raceRef.collection("members").document(user.uid))

            if let passcode {
                let inviteHash = self.hashPasscode(passcode)
                batch.setData([
                    "raceId": raceRef.documentID,
                    "ownerId": user.uid,
                    "expiresAt": Timestamp(date: Date().addingTimeInterval(72 * 60 * 60)),
                    "createdAt": FieldValue.serverTimestamp()
                ], forDocument: self.database.collection("raceInvites").document(inviteHash))
            }

            try await batch.commit()
            self.activeRace = ConnectedRace(
                id: raceRef.documentID,
                raceName: cleanRaceName,
                runnerName: cleanRunnerName,
                targetDistanceMiles: targetDistanceMiles,
                isPrivate: isPrivate,
                passcode: passcode,
                isOwner: true,
                status: "setup",
                wasRestored: false
            )
            self.saveActiveRace(raceId: raceRef.documentID, userId: user.uid)
        }
    }

    func joinRace(passcode: String) async {
        await perform {
            let user = try await self.spectatorUser()
            let normalized = self.normalizePasscode(passcode)
            guard normalized.count == 8 else {
                throw RaceStoreError.invalidPasscode
            }

            let inviteHash = self.hashPasscode(normalized)
            let invite = try await self.database
                .collection("raceInvites")
                .document(inviteHash)
                .getDocument()
            guard let inviteData = invite.data(),
                  let raceId = inviteData["raceId"] as? String,
                  let ownerId = inviteData["ownerId"] as? String,
                  let expiresAt = inviteData["expiresAt"] as? Timestamp else {
                throw RaceStoreError.passcodeNotFound
            }
            guard expiresAt.dateValue() > Date() else {
                throw RaceStoreError.passcodeExpired
            }

            let raceRef = self.database.collection("races").document(raceId)
            if ownerId != user.uid {
                try await self.ensureSpectatorMembership(
                    raceRef: raceRef,
                    userId: user.uid,
                    inviteHash: inviteHash
                )
            }
            let race = try await raceRef.getDocument()
            self.activeRace = try self.connectedRace(
                from: race,
                passcode: ownerId == user.uid ? normalized : nil,
                isOwner: ownerId == user.uid,
                wasRestored: false
            )
            self.saveActiveRace(raceId: raceId, userId: user.uid)
        }
    }

    func loadPublicRaces() async {
        isLoadingPublicRaces = true
        defer { isLoadingPublicRaces = false }

        do {
            let snapshot = try await database
                .collection("races")
                .whereField("isPrivate", isEqualTo: false)
                .limit(to: 50)
                .getDocuments()

            publicRaces = snapshot.documents
                .compactMap(publicRace(from:))
                .filter { $0.status != "ended" }
        } catch {
            alertTitle = "Couldn’t load public races"
            errorMessage = userFacingMessage(for: error as NSError)
        }
    }

    func loadMyRaces() async {
        guard let user = auth.currentUser, !user.isAnonymous else {
            myRaces = []
            return
        }
        isLoadingMyRaces = true
        defer { isLoadingMyRaces = false }

        do {
            let snapshot = try await database
                .collection("races")
                .whereField("ownerId", isEqualTo: user.uid)
                .limit(to: 50)
                .getDocuments()

            myRaces = snapshot.documents
                .compactMap(myRace(from:))
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            alertTitle = "Couldn’t load your races"
            errorMessage = userFacingMessage(for: error as NSError)
        }
    }

    func openMyRace(_ race: MyRace) async {
        await perform {
            guard let user = self.auth.currentUser, !user.isAnonymous else {
                throw RaceStoreError.creatorAccountRequired
            }
            let snapshot = try await self.database
                .collection("races")
                .document(race.id)
                .getDocument()
            guard snapshot.data()?["ownerId"] as? String == user.uid else {
                throw RaceStoreError.raceUnavailable
            }
            self.activeRace = try self.connectedRace(
                from: snapshot,
                passcode: nil,
                isOwner: true,
                wasRestored: true
            )
            self.saveActiveRace(raceId: race.id, userId: user.uid)
        }
    }

    func joinPublicRace(_ race: PublicRace) async {
        await perform {
            let user = try await self.spectatorUser()
            let raceRef = self.database.collection("races").document(race.id)
            let isOwner = race.ownerId == user.uid

            if !isOwner {
                try await self.ensureSpectatorMembership(
                    raceRef: raceRef,
                    userId: user.uid,
                    inviteHash: nil
                )
            }
            let snapshot = try await raceRef.getDocument()
            self.activeRace = try self.connectedRace(
                from: snapshot,
                passcode: nil,
                isOwner: isOwner,
                wasRestored: false
            )
            self.saveActiveRace(raceId: race.id, userId: user.uid)
        }
    }

    func leaveRace(preserveSession: Bool = false) {
        if !preserveSession {
            sessionStore.clear()
        }
        activeRace = nil
        canRetryRaceRecovery = false
    }

    func retryRaceRecovery() async {
        guard let user = auth.currentUser else { return }
        await restoreActiveRace(for: user)
    }

    func discardSavedRace() {
        sessionStore.clear()
        activeRace = nil
        canRetryRaceRecovery = false
    }

    private func spectatorUser() async throws -> User {
        if let user = auth.currentUser {
            if user.isAnonymous {
                return user
            }
            try auth.signOut()
        }
        return try await auth.signInAnonymously().user
    }

    private func ensureSpectatorMembership(
        raceRef: DocumentReference,
        userId: String,
        inviteHash: String?
    ) async throws {
        let memberRef = raceRef.collection("members").document(userId)
        do {
            let existingMember = try await memberRef.getDocument()
            guard existingMember.data()?["role"] as? String == "spectator" else {
                throw RaceStoreError.raceUnavailable
            }
            return
        } catch {
            let firestoreError = error as NSError
            guard firestoreError.domain == FirestoreErrorDomain,
                  firestoreError.code == FirestoreErrorCode.permissionDenied.rawValue else {
                throw error
            }
        }

        var membership: [String: Any] = [
            "role": "spectator",
            "joinedAt": FieldValue.serverTimestamp()
        ]
        if let inviteHash {
            membership["inviteHash"] = inviteHash
        }
        try await memberRef.setData(membership)
    }

    private func connectedRace(
        from snapshot: DocumentSnapshot,
        passcode: String?,
        isOwner: Bool,
        wasRestored: Bool
    ) throws -> ConnectedRace {
        guard let data = snapshot.data(),
              let raceName = data["raceName"] as? String,
              let runnerName = data["runnerName"] as? String,
              let distance = data["targetDistanceMiles"] as? NSNumber,
              let isPrivate = data["isPrivate"] as? Bool else {
            throw RaceStoreError.raceUnavailable
        }
        return ConnectedRace(
            id: snapshot.documentID,
            raceName: raceName,
            runnerName: runnerName,
            targetDistanceMiles: distance.doubleValue,
            isPrivate: isPrivate,
            passcode: passcode,
            isOwner: isOwner,
            status: data["status"] as? String ?? "setup",
            wasRestored: wasRestored
        )
    }

    private func handleAuthChange(_ user: User?) async {
        self.user = user
        if user == nil || user?.isAnonymous == true {
            myRaces = []
        }
        guard let session = sessionStore.load() else {
            isRestoringRace = false
            canRetryRaceRecovery = false
            return
        }
        guard let user else {
            activeRace = nil
            isRestoringRace = false
            return
        }
        guard session.userId == user.uid else {
            sessionStore.clear()
            activeRace = nil
            isRestoringRace = false
            canRetryRaceRecovery = false
            return
        }
        guard activeRace?.id != session.raceId else {
            isRestoringRace = false
            return
        }
        await restoreActiveRace(for: user)
    }

    private func restoreActiveRace(for user: User) async {
        guard let session = sessionStore.load(),
              session.userId == user.uid else {
            isRestoringRace = false
            canRetryRaceRecovery = false
            return
        }

        isRestoringRace = true
        canRetryRaceRecovery = false
        defer { isRestoringRace = false }

        do {
            let raceRef = database.collection("races").document(session.raceId)
            let snapshot = try await raceRef.getDocument()
            guard let ownerId = snapshot.data()?["ownerId"] as? String else {
                throw RaceStoreError.raceUnavailable
            }
            let isOwner = ownerId == user.uid
            if !isOwner {
                let membership = try await raceRef
                    .collection("members")
                    .document(user.uid)
                    .getDocument()
                guard membership.data()?["role"] as? String == "spectator" else {
                    throw RaceStoreError.raceUnavailable
                }
            }
            activeRace = try connectedRace(
                from: snapshot,
                passcode: nil,
                isOwner: isOwner,
                wasRestored: true
            )
        } catch {
            canRetryRaceRecovery = true
            alertTitle = "Couldn’t restore your race"
            errorMessage = userFacingMessage(for: error as NSError)
        }
    }

    private func saveActiveRace(raceId: String, userId: String) {
        sessionStore.save(ActiveRaceSession(raceId: raceId, userId: userId))
        canRetryRaceRecovery = false
    }

    private func publicRace(from snapshot: QueryDocumentSnapshot) -> PublicRace? {
        let data = snapshot.data()
        guard let raceName = data["raceName"] as? String,
              let runnerName = data["runnerName"] as? String,
              let distance = data["targetDistanceMiles"] as? NSNumber,
              let ownerId = data["ownerId"] as? String else {
            return nil
        }
        return PublicRace(
            id: snapshot.documentID,
            raceName: raceName,
            runnerName: runnerName,
            targetDistanceMiles: distance.doubleValue,
            status: data["status"] as? String ?? "setup",
            ownerId: ownerId
        )
    }

    private func myRace(from snapshot: QueryDocumentSnapshot) -> MyRace? {
        let data = snapshot.data()
        guard let raceName = data["raceName"] as? String,
              let runnerName = data["runnerName"] as? String,
              let distance = data["targetDistanceMiles"] as? NSNumber,
              let isPrivate = data["isPrivate"] as? Bool else {
            return nil
        }
        return MyRace(
            id: snapshot.documentID,
            raceName: raceName,
            runnerName: runnerName,
            targetDistanceMiles: distance.doubleValue,
            isPrivate: isPrivate,
            status: data["status"] as? String ?? "setup",
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
        )
    }

    private func validatedText(_ value: String, field: String, limit: Int) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit else {
            throw RaceStoreError.invalidText(field: field, limit: limit)
        }
        return text
    }

    private func normalizePasscode(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private func hashPasscode(_ passcode: String) -> String {
        SHA256.hash(data: Data(passcode.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func randomPasscode() throws -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RaceStoreError.randomGenerationFailed
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        alertTitle = "Something went wrong"
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await work()
        } catch {
            errorMessage = userFacingMessage(for: error as NSError)
        }
    }

    private func userFacingMessage(for error: NSError) -> String {
        if error.domain == AuthErrorDomain,
           let authCode = AuthErrorCode(rawValue: error.code) {
            switch authCode {
            case .invalidCredential, .wrongPassword, .userNotFound:
                return "That email and password don’t match an account. If this is your first time, tap “Create a new account.”"
            case .emailAlreadyInUse:
                return "An account already uses that email. Sign in instead, or reset your password."
            case .weakPassword:
                return "Choose a stronger password with at least 6 characters."
            case .invalidEmail:
                return "Enter a valid email address."
            case .operationNotAllowed:
                return "This sign-in method is not enabled in Firebase Authentication."
            case .networkError:
                return "Couldn’t reach Firebase. Check your internet connection and try again."
            case .userDisabled:
                return "This account has been disabled."
            default:
                break
            }
        }

        if error.domain == FirestoreErrorDomain,
           error.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "Firestore denied this request. Deploy the included Firestore rules, then try again."
        }
        return error.localizedDescription
    }
}

private enum RaceStoreError: LocalizedError {
    case creatorAccountRequired
    case invalidDistance
    case invalidPasscode
    case invalidText(field: String, limit: Int)
    case passcodeNotFound
    case passcodeExpired
    case raceUnavailable
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .creatorAccountRequired:
            "Sign in with a creator account first."
        case .invalidDistance:
            "Distance must be between 0.1 and 500 miles."
        case .invalidPasscode:
            "Enter the complete 8-character passcode."
        case let .invalidText(field, limit):
            "\(field) must be between 1 and \(limit) characters."
        case .passcodeNotFound:
            "That passcode was not found."
        case .passcodeExpired:
            "That passcode has expired."
        case .raceUnavailable:
            "That race is no longer available."
        case .randomGenerationFailed:
            "Couldn’t create a secure passcode. Please try again."
        }
    }
}
