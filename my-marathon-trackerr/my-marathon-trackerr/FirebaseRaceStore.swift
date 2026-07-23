import FirebaseAuth
import FirebaseFunctions
import Foundation

struct ConnectedRace: Identifiable, Equatable {
    let id: String
    let raceName: String
    let runnerName: String
    let targetDistanceMiles: Double
    let isPrivate: Bool
    let passcode: String?
    let isOwner: Bool
}

@MainActor
final class FirebaseRaceStore: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var activeRace: ConnectedRace?
    @Published private(set) var isWorking = false
    @Published var alertTitle = "Something went wrong"
    @Published var errorMessage: String?

    private let auth = Auth.auth()
    private let functions = Functions.functions()
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
            guard self.isCreatorSignedIn else {
                throw RaceStoreError.creatorAccountRequired
            }

            let result = try await self.functions
                .httpsCallable("createRace")
                .call([
                    "raceName": raceName,
                    "runnerName": runnerName,
                    "targetDistanceMiles": targetDistanceMiles,
                    "isPrivate": isPrivate
                ])
            guard let data = result.data as? [String: Any],
                  let raceId = data["raceId"] as? String,
                  let returnedRaceName = data["raceName"] as? String,
                  let returnedRunnerName = data["runnerName"] as? String,
                  let returnedDistance = data["targetDistanceMiles"] as? Double else {
                throw RaceStoreError.invalidServerResponse
            }

            self.activeRace = ConnectedRace(
                id: raceId,
                raceName: returnedRaceName,
                runnerName: returnedRunnerName,
                targetDistanceMiles: returnedDistance,
                isPrivate: data["isPrivate"] as? Bool ?? isPrivate,
                passcode: data["passcode"] as? String,
                isOwner: true
            )
        }
    }

    func joinRace(passcode: String) async {
        await perform {
            if self.auth.currentUser == nil {
                _ = try await self.auth.signInAnonymously()
            }

            let normalized = passcode
                .uppercased()
                .filter { $0.isLetter || $0.isNumber }
            let result = try await self.functions
                .httpsCallable("joinRace")
                .call(["passcode": normalized])
            guard let data = result.data as? [String: Any],
                  let raceId = data["raceId"] as? String,
                  let raceName = data["raceName"] as? String,
                  let runnerName = data["runnerName"] as? String,
                  let targetDistanceMiles = data["targetDistanceMiles"] as? Double else {
                throw RaceStoreError.invalidServerResponse
            }

            self.activeRace = ConnectedRace(
                id: raceId,
                raceName: raceName,
                runnerName: runnerName,
                targetDistanceMiles: targetDistanceMiles,
                isPrivate: data["isPrivate"] as? Bool ?? true,
                passcode: nil,
                isOwner: false
            )
        }
    }

    func leaveRace() {
        activeRace = nil
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        alertTitle = "Something went wrong"
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await work()
        } catch {
            let nsError = error as NSError
            errorMessage = userFacingMessage(for: nsError)
        }
    }

    private func userFacingMessage(for error: NSError) -> String {
        guard error.domain == AuthErrorDomain,
              let authCode = AuthErrorCode(rawValue: error.code) else {
            return error.localizedDescription
        }

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
            return "Email/Password sign-in is not enabled in Firebase Authentication."
        case .networkError:
            return "Couldn’t reach Firebase. Check your internet connection and try again."
        case .userDisabled:
            return "This account has been disabled."
        default:
            return error.localizedDescription
        }
    }
}

private enum RaceStoreError: LocalizedError {
    case creatorAccountRequired
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .creatorAccountRequired:
            "Sign in with a creator account first."
        case .invalidServerResponse:
            "Firebase returned an unexpected response. Please try again."
        }
    }
}
