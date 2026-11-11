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
public final class AppleAccount: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding, ASWebAuthenticationPresentationContextProviding {
    public static let shared = AppleAccount()
    @Published public private(set) var displayName: String?
    @Published public private(set) var email: String?
    @Published public private(set) var isSignedIn = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    private var generation = UUID()
    private var webSession: ASWebAuthenticationSession?
    private var webExchange: URLSessionDataTask?
    private var verifiedWebUser: String?
    private var webVerifiedUntil: Date?
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
        var method: String?
    }
    public var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SoundboundAppleSignInConfigured") as? Bool == true
    }
    public var isWebConfigured: Bool { webAuthURL != nil }
    private var webAuthURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SoundboundAppleWebAuthURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
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
        generation = UUID()
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
            let fresh = Profile(user: credential.user, name: name, email: credential.email ?? old?.email, method: "native")
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
        guard !isBusy, let profile else { return }
        if profile.method == "web" {
            isSignedIn = verifiedWebUser == profile.user && (webVerifiedUntil ?? .distantPast) > Date()
            return
        }
        guard isConfigured else { return }
        let requestedGeneration = generation
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: profile.user) { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self, self.generation == requestedGeneration,
                      self.profile?.user == profile.user, self.profile?.method != "web" else { return }
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
    public func cancelSignIn() {
        generation = UUID()
        let pending = authorizationController
        clearAuthorization()
        pending?.cancel()
        webSession?.cancel(); webSession = nil
        webExchange?.cancel(); webExchange = nil
        expectedState = nil; isBusy = false
        message = nil
    }
    public func signOut() {
        cancelSignIn()
        verifiedWebUser = nil; webVerifiedUntil = nil
        defaults.removeObject(forKey: Self.profileKey)
        displayName = nil; email = nil; isSignedIn = false; isBusy = false; expectedState = nil; message = nil
    }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        authorizationWindow ?? ASPresentationAnchor()
    }
    public func useAnotherAccount(in anchor: ASPresentationAnchor? = nil) {
        guard !isBusy else { return }
        guard let startURL = webAuthURL else {
            message = "The Apple web sign-in service is not configured in this build."
            return
        }
        guard let window = anchor ?? currentWindow else {
            message = "Open Soundbound’s Settings window, then try again."
            return
        }
        signOut()
        let attempt = UUID(); generation = attempt
        let state = Self.randomURLToken()
        let verifier = Self.randomURLToken()
        let nonce = Self.randomURLToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        expectedState = state; authorizationWindow = window; isBusy = true
        var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state),
                                 URLQueryItem(name: "code_challenge", value: challenge),
                                 URLQueryItem(name: "nonce", value: nonce)]
        let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "soundbound") { [weak self] url, error in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.isBusy else { return }
                self.webSession = nil
                if let error {
                    self.cancelSignIn()
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.message = "Apple’s sign-in page could not finish. Check your connection and try again."
                    }
                    return
                }
                switch AppleWebCallback.parse(url, expectedState: state) {
                case .success(let code):
                    self.redeem(code: code, verifier: verifier, startURL: startURL, attempt: attempt)
                case .failure(let failure):
                    self.cancelSignIn()
                    self.message = failure.message
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        webSession = session
        if !session.start() {
            cancelSignIn(); message = "Apple’s sign-in window could not open. Please try again."
        }
    }
    private var currentWindow: ASPresentationAnchor? {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        #else
        return NSApp.keyWindow ?? NSApp.mainWindow
        #endif
    }
    private struct WebProfile: Decodable {
        var provider: String
        var subject: String
        var name: String?
        var email: String?
        var expiresAt: TimeInterval
    }
    private func redeem(code: String, verifier: String, startURL: URL, attempt: UUID) {
        let endpoint = startURL.deletingLastPathComponent().appendingPathComponent("redeem")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["code": code, "code_verifier": verifier])
        let session = URLSession(configuration: .ephemeral, delegate: AppleAuthNoRedirect(), delegateQueue: nil)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.isBusy else { return }
                self.webExchange = nil; self.authorizationWindow = nil; self.isBusy = false; self.expectedState = nil
                guard error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let data, data.count < 16_384, let result = try? JSONDecoder().decode(WebProfile.self, from: data),
                      result.provider == "apple", !result.subject.isEmpty, result.subject.count < 256,
                      result.expiresAt > Date().timeIntervalSince1970 else {
                    self.message = "Apple account verification failed. Please try again."
                    return
                }
                let profile = Profile(user: result.subject, name: result.name, email: result.email, method: "web")
                if let encoded = try? JSONEncoder().encode(profile) { self.defaults.set(encoded, forKey: Self.profileKey) }
                self.verifiedWebUser = result.subject
                self.webVerifiedUntil = Date(timeIntervalSince1970: min(result.expiresAt, Date().addingTimeInterval(3600).timeIntervalSince1970))
                self.displayName = result.name; self.email = result.email; self.isSignedIn = true
                self.message = nil
            }
        }
        webExchange = task; task.resume()
    }
    private static func randomURLToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64URLEncoded
    }

}

public struct AppleAccountView: View {
    @ObservedObject private var account = AppleAccount.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingOptions = false
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            if account.isSignedIn {
                Label(account.displayName ?? "Signed in with Apple", systemImage: "person.crop.circle.fill").font(.headline)
                if let email = account.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                if account.displayName != nil || account.email != nil {
                    Text("Signed in on this device").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                AppleAuthorizationButton(account: account)
                    .frame(width: 220, height: 44)
                    .disabled(account.isBusy || !account.isConfigured)
                if !account.isConfigured {
                    Text("Apple sign-in needs the signed development build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if account.isBusy {
                Button("Cancel sign-in") { account.cancelSignIn() }.buttonStyle(.bordered)
            } else {
                DisclosureGroup("Account options", isExpanded: $showingOptions) {
                    VStack(spacing: 12) {
                        if account.isSignedIn {
                            Button("Sign out") { account.signOut(); showingOptions = false }.buttonStyle(.bordered)
                        }
                        AppleWebAccountButton(account: account)
                            .frame(width: 220, height: 32)
                            .disabled(!account.isWebConfigured)
                        if !account.isWebConfigured {
                            Text("Account switching is waiting for the Apple web sign-in service.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity).padding(.top, 12)
                }
                .frame(maxWidth: 300)
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

private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
private final class AppleAuthNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

#if os(iOS)
private final class AppleWebAccountButtonCoordinator: NSObject {
    let account: AppleAccount
    init(_ account: AppleAccount) { self.account = account }
    @objc func pressed(_ sender: UIButton) { account.useAnotherAccount(in: sender.window) }
}
private struct AppleWebAccountButton: UIViewRepresentable {
    let account: AppleAccount
    func makeCoordinator() -> AppleWebAccountButtonCoordinator { AppleWebAccountButtonCoordinator(account) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Use another Apple Account", for: .normal)
        button.addTarget(context.coordinator, action: #selector(AppleWebAccountButtonCoordinator.pressed(_:)), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) { button.isEnabled = context.environment.isEnabled }
}
#else
private final class AppleWebAccountButtonCoordinator: NSObject {
    let account: AppleAccount
    init(_ account: AppleAccount) { self.account = account }
    @objc func pressed(_ sender: NSButton) { account.useAnotherAccount(in: sender.window) }
}
private struct AppleWebAccountButton: NSViewRepresentable {
    let account: AppleAccount
    func makeCoordinator() -> AppleWebAccountButtonCoordinator { AppleWebAccountButtonCoordinator(account) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Use another Apple Account", target: context.coordinator,
                              action: #selector(AppleWebAccountButtonCoordinator.pressed(_:)))
        button.isBordered = false
        button.contentTintColor = .systemBlue
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { button.isEnabled = context.environment.isEnabled }
}
#endif
