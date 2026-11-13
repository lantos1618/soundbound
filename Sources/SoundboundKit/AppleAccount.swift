import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Apple authorization for this installation. Display metadata alone grants no
/// permissions. Device-bound identity assertions are stored; access/refresh tokens are not.
public final class AppleAccount: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding, ASWebAuthenticationPresentationContextProviding {
    public static let shared = AppleAccount()
    @Published public private(set) var displayName: String?
    @Published public private(set) var email: String?
    @Published public private(set) var isSignedIn = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var isCheckingCredential = false
    @Published public private(set) var message: String?
    private var generation = UUID()
    private var webSession: ASWebAuthenticationSession?
    private var webExchange: URLSessionDataTask?
    // End locally before the broker's ten-minute flow expires, including
    // when the Mac sleeps while Apple's page is open.
    private var webSignInDeadline: Date?
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
        /// Apple's signed identity token from a sign-in whose nonce was bound to this device's key.
        var proof: String?
    }
    /// The person's name as this computer knows it. iPhone offers no equivalent.
    static var deviceOwnerName: String? {
        #if os(macOS)
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(60))
        #else
        return nil
        #endif
    }
    /// Reads the email from our own freshly issued identity token, for display only.
    static func emailClaim(_ token: String) -> String? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let data = Data(url64: parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty, email.count <= 254 else { return nil }
        return email
    }
    /// This device's public key. Set once the device identity is loaded; sign-in binds to it.
    public var deviceBinding: String?
    private var signInBoundTo: String?
    /// The Apple account subject from the currently verified sign-in.
    public var accountID: String? {
        guard isSignedIn, let profile else { return nil }
        if profile.method == "web", (webVerifiedUntil ?? .distantPast) <= Date() { return nil }
        return profile.user
    }
    /// Proof other paired devices can check to see that this device belongs to `accountID`.
    public var accountProof: String? {
        guard accountID != nil, let proof = profile?.proof, let deviceBinding,
              AppleAccountProof.isBound(proof, to: deviceBinding) else { return nil }
        return proof
    }
    public var canLinkDevices: Bool { accountProof != nil }
    public var usesWebSignIn: Bool { isSignedIn && profile?.method == "web" }
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
        isCheckingCredential = false
        let state = UUID().uuidString
        expectedState = state
        request.state = state
        request.requestedScopes = [.fullName, .email]
        // Bind the authorization to a fresh request. A future account backend
        // must independently verify Apple's token and nonce before granting access.
        signInBoundTo = deviceBinding
        // Bound to this device's key so the signed token proves "this account, on this device". Without a
        // loaded identity it falls back to a random value and no proof is kept.
        request.nonce = deviceBinding.map(AppleAccountProof.nonce(forDevice:))
            ?? SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
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
            // Apple sends the name only the very first time an account authorises this app, so fall back to what
            // is already known: the saved profile, then the name on this Mac's user account.
            let name = formatted.flatMap { $0.isEmpty ? nil : $0 } ?? old?.name ?? Self.deviceOwnerName
            let rawToken = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
            let token = signInBoundTo != nil ? rawToken : nil
            // The email, unlike the name, is in every identity token.
            let address = credential.email ?? old?.email ?? rawToken.flatMap(Self.emailClaim)
            let fresh = Profile(user: credential.user, name: name, email: address, method: "native", proof: token)
            // Display metadata plus the device-bound identity token. The token is an assertion about this
            // device's key only; it is not an access or refresh token and grants nothing at Apple.
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
        if expireWebSignInIfNeeded() { return }
        guard !isBusy, !isCheckingCredential, let profile else { return }
        if profile.method == "web" {
            isSignedIn = verifiedWebUser == profile.user && (webVerifiedUntil ?? .distantPast) > Date()
            return
        }
        guard isConfigured else { return }
        isCheckingCredential = true
        let requestedGeneration = generation
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: profile.user) { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self, self.generation == requestedGeneration,
                      self.profile?.user == profile.user, self.profile?.method != "web" else { return }
                self.isCheckingCredential = false
                if state == .authorized {
                    self.displayName = profile.name ?? Self.deviceOwnerName
                    self.email = profile.email ?? profile.proof.flatMap(Self.emailClaim); self.isSignedIn = true
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
        isCheckingCredential = false
        let pending = authorizationController
        clearAuthorization()
        pending?.cancel()
        webSession?.cancel(); webSession = nil
        webExchange?.cancel(); webExchange = nil
        webSignInDeadline = nil
        expectedState = nil; isBusy = false
        message = nil
    }
    @discardableResult
    private func expireWebSignInIfNeeded() -> Bool {
        guard let deadline = webSignInDeadline, Date() >= deadline else { return false }
        cancelSignIn()
        message = "This sign-in attempt timed out. Choose Use another Apple Account to start again. Your existing Soundbound account has not changed."
        return true
    }
    public func signOut() {
        cancelSignIn()
        isCheckingCredential = false
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
        // Keep the current account until the replacement has been verified.
        // Cancelling or failing account selection must not sign the user out.
        let attempt = UUID(); generation = attempt
        isCheckingCredential = false
        let state = Self.randomURLToken()
        let verifier = Self.randomURLToken()
        let binding = deviceBinding
        let nonce = binding.map(AppleAccountProof.nonce(forDevice:)) ?? Self.randomURLToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        expectedState = state; authorizationWindow = window; isBusy = true
        webSignInDeadline = Date().addingTimeInterval(9 * 60)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == attempt else { return }
            self.expireWebSignInIfNeeded()
        }
        authorizationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 9 * 60, execute: timeout)
        var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state),
                                 URLQueryItem(name: "code_challenge", value: challenge),
                                 URLQueryItem(name: "nonce", value: nonce)]
        let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "soundbound") { [weak self] url, error in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, self.isBusy else { return }
                guard !self.expireWebSignInIfNeeded() else { return }
                self.authorizationTimeout?.cancel(); self.authorizationTimeout = nil
                self.webSignInDeadline = nil
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
                    self.redeem(code: code, verifier: verifier, startURL: startURL, attempt: attempt, binding: binding)
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
        var deviceProof: String?
    }
    private func redeem(code: String, verifier: String, startURL: URL, attempt: UUID, binding: String?) {
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
                let deviceProof = result.deviceProof.flatMap { token in
                    binding == self.deviceBinding && token.utf8.count <= 4096 && binding.map({ AppleAccountProof.isBound(token, to: $0) }) == true ? token : nil
                }
                let profile = Profile(user: result.subject, name: result.name, email: result.email, method: "web", proof: deviceProof)
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
    public init() {}
    private var signedOutText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sign in to Soundbound").font(.headline)
            Text("Your devices signed in to the same Apple Account connect automatically when Soundbound is open on the same local network.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Narrow layouts: the button spans the card so it reads as the one thing to do.
    private var wideSignInButton: some View {
        AppleAuthorizationButton(account: account)
            .frame(maxWidth: .infinity).frame(height: 46)
            .disabled(account.isBusy || !account.isConfigured)
    }
    private var signInButton: some View {
        AppleAuthorizationButton(account: account)
            .frame(width: 200, height: 36)
            .disabled(account.isBusy || !account.isConfigured)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if account.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        // A name when there is one, otherwise the email; never the same line twice.
                        Text(account.displayName ?? account.email ?? "Signed in with Apple").font(.headline).lineLimit(1)
                        if account.displayName != nil, let email = account.email {
                            Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(account.usesWebSignIn ? "Apple Account · Web sign-in" : "Apple Account · Native sign-in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Sign out") { account.signOut() }.buttonStyle(.bordered)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { signedOutText; Spacer(minLength: 12); signInButton }
                    VStack(alignment: .leading, spacing: 12) { signedOutText; wideSignInButton }
                }
                if !account.isConfigured {
                    Text("Apple sign-in needs the signed development build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = account.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if account.isWebConfigured {
                Button(account.isBusy ? "Cancel sign-in" : "Use another Apple Account") {
                    if account.isBusy { account.cancelSignIn() } else { account.useAnotherAccount() }
                }
                    .buttonStyle(.plain).font(.subheadline).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: account.isSignedIn ? .leading : .center)
                    .help("Opens Apple’s website so you can use a different account.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

