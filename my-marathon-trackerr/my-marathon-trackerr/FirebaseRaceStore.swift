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
}

struct PublicRace: Identifiable, Equatable {
    let id: String
    let raceName: String
    let runnerName: String
    let targetDistanceMiles: Double
    let status: String
    let ownerId: String
}

@MainActor
final class FirebaseRaceStore: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var activeRace: ConnectedRace?
    @Published private(set) var publicRaces: [PublicRace] = []
    @Published private(set) var isLoadingPublicRaces = false
    @Published private(set) var isWorking = false
    @Published var alertTitle = "Something went wrong"
    @Published var errorMessage: String?

    private let auth = Auth.auth()
    private let database = Firestore.firestore()
    private var authHandle: AuthStateDidChangeListenerHandle?

    init() {
        user = auth.currentUser
        authHandle = auth.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
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
            try auth.signOut()
            activeRace = nil
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
                isOwner: true
            )
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
                try await raceRef.collection("members").document(user.uid).setData([
                    "role": "spectator",
                    "inviteHash": inviteHash,
                    "joinedAt": FieldValue.serverTimestamp()
                ])
            }
            let race = try await raceRef.getDocument()
            self.activeRace = try self.connectedRace(
                from: race,
                passcode: ownerId == user.uid ? normalized : nil,
                isOwner: ownerId == user.uid
            )
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

    func joinPublicRace(_ race: PublicRace) async {
        await perform {
            let user = try await self.spectatorUser()
            let raceRef = self.database.collection("races").document(race.id)
            let isOwner = race.ownerId == user.uid

            if !isOwner {
                try await raceRef.collection("members").document(user.uid).setData([
                    "role": "spectator",
                    "joinedAt": FieldValue.serverTimestamp()
                ])
            }
            let snapshot = try await raceRef.getDocument()
            self.activeRace = try self.connectedRace(
                from: snapshot,
                passcode: nil,
                isOwner: isOwner
            )
        }
    }

    func leaveRace() {
        activeRace = nil
    }

    private func spectatorUser() async throws -> User {
        if let user = auth.currentUser {
            return user
        }
        return try await auth.signInAnonymously().user
    }

    private func connectedRace(
        from snapshot: DocumentSnapshot,
        passcode: String?,
        isOwner: Bool
    ) throws -> ConnectedRace {
        guard let data = snapshot.data(),
              data["status"] as? String != "ended",
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
            isOwner: isOwner
        )
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
