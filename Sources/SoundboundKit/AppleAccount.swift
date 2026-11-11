import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Apple authorization for this installation. Cached profile data never grants
/// room permissions, and identity/access tokens are not persisted by the app.
public final class AppleAccount: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    public static let shared = AppleAccount()
    @Published public private(set) var displayName: String?
    @Published public private(set) var email: String?
    @Published public private(set) var isSignedIn = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    private var expectedState: String?
    private var authorizationController: ASAuthorizationController?
    private var authorizationWindow: ASPresentationAnchor?
    private var authorizationTimeout: DispatchWorkItem?
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private static let profileKey = "Soundbound.appleProfile.v1"

    private struct Profile: Codable {
        var user: String
        var name: String?
        var email: String?
    }
    public var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SoundboundAppleSignInConfigured") as? Bool == true
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        observer = NotificationCenter.default.addObserver(forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main) { [weak self] _ in self?.signOut() }
        refreshCredential()
    }
    deinit {
        authorizationTimeout?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    private var profile: Profile? {
        defaults.data(forKey: Self.profileKey).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }
    }
    public func signIn(in window: ASPresentationAnchor?) {
        guard !isBusy else { return }
        guard isConfigured, let window else {
            message = "Open Settings in the signed Soundbound app, then try again."
            return
        }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        prepare(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        // Both delegate properties are weak. Retain the controller and its
        // presentation anchor for the full authorization, including sheet changes.
        authorizationWindow = window
        authorizationController = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        let timeout = DispatchWorkItem { [weak self, weak controller] in
            guard let self, self.authorizationController === controller else { return }
            self.authorizationController = nil
            controller?.cancel()
            self.authorizationWindow = nil
            self.isBusy = false
            self.expectedState = nil
            self.message = "Apple sign-in timed out. Please try again."
        }
        authorizationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        controller.performRequests()
    }
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // signIn refuses to begin until the real hosting window is available.
        if let authorizationWindow { return authorizationWindow }
        // An already-cancelled controller may request an anchor late. Return an
        // empty anchor rather than dereferencing a window released on timeout.
        return ASPresentationAnchor()
    }
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard authorizationController === controller else { return }
        complete(.success(authorization))
        clearAuthorization()
    }
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard authorizationController === controller else { return }
        complete(.failure(error))
        clearAuthorization()
    }
    private func clearAuthorization() {
        authorizationTimeout?.cancel(); authorizationTimeout = nil
        authorizationController = nil; authorizationWindow = nil
    }
    public func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let state = UUID().uuidString
        expectedState = state
        request.state = state
        request.requestedScopes = [.fullName, .email]
        // Bind the authorization to a fresh request. A future account backend
        // must independently verify Apple's token and nonce before granting access.
        request.nonce = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        isBusy = true; message = nil
    }
    public func complete(_ result: Result<ASAuthorization, Error>) {
        isBusy = false
        defer { expectedState = nil }
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  !credential.user.isEmpty, let state = expectedState, credential.state == state else {
                message = "Apple sign-in could not be verified. Please try again."
                return
            }
            let old = profile.flatMap { $0.user == credential.user ? $0 : nil }
            let formatted = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
            let name = formatted.flatMap { $0.isEmpty ? nil : $0 } ?? old?.name
            let fresh = Profile(user: credential.user, name: name, email: credential.email ?? old?.email)
            // This is display metadata, not a stored bearer credential.
            if let data = try? JSONEncoder().encode(fresh) { defaults.set(data, forKey: Self.profileKey) }
            displayName = fresh.name; email = fresh.email
            isSignedIn = true
            message = nil
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                message = "Apple sign-in failed. Check your Apple Account and try again."
            }
        }
    }
    public func refreshCredential() {
        guard isConfigured, let profile else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: profile.user) { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if state == .authorized {
                    self.displayName = profile.name; self.email = profile.email; self.isSignedIn = true
                } else if error == nil {
                    self.signOut()
                } else {
                    self.isSignedIn = false
                    self.message = "Couldn’t check Apple sign-in. Try again when you’re online."
                }
            }
        }
    }
    public func signOut() {
        let pending = authorizationController
        clearAuthorization()
        pending?.cancel()
        defaults.removeObject(forKey: Self.profileKey)
        displayName = nil; email = nil; isSignedIn = false; isBusy = false; expectedState = nil; message = nil
    }
}

public struct AppleAccountView: View {
    @ObservedObject private var account = AppleAccount.shared
    @Environment(\.scenePhase) private var scenePhase
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            if account.isSignedIn {
                Label(account.displayName ?? "Apple Account", systemImage: "person.crop.circle.fill").font(.headline)
                if let email = account.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                Text("Signed in on this device").font(.caption).foregroundStyle(.secondary)
                Button("Sign out") { account.signOut() }.buttonStyle(.bordered)
            } else {
                AppleAuthorizationButton(account: account)
                    .frame(width: 220, height: 44)
                    .disabled(account.isBusy || !account.isConfigured)
                if !account.isConfigured {
                    Text("Apple sign-in needs the signed development build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = account.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: scenePhase) { phase in if phase == .active { account.refreshCredential() } }
    }
}

private final class AppleAuthorizationButtonCoordinator: NSObject {
    let account: AppleAccount
    init(_ account: AppleAccount) { self.account = account }
    @objc func pressed(_ sender: ASAuthorizationAppleIDButton) { account.signIn(in: sender.window) }
}

#if os(iOS)
private struct AppleAuthorizationButton: UIViewRepresentable {
    let account: AppleAccount
    func makeCoordinator() -> AppleAuthorizationButtonCoordinator { AppleAuthorizationButtonCoordinator(account) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        button.addTarget(context.coordinator, action: #selector(AppleAuthorizationButtonCoordinator.pressed(_:)), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) { button.isEnabled = context.environment.isEnabled }
}
#else
private struct AppleAuthorizationButton: NSViewRepresentable {
    let account: AppleAccount
    func makeCoordinator() -> AppleAuthorizationButtonCoordinator { AppleAuthorizationButtonCoordinator(account) }
    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        button.target = context.coordinator
        button.action = #selector(AppleAuthorizationButtonCoordinator.pressed(_:))
        return button
    }
    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) { button.isEnabled = context.environment.isEnabled }
}
#endif
