import CryptoKit
import Foundation

/// The per-build secrets build-and-sign embeds in the app bundle.
///
/// `DebugTraceCredential.plist` sits at the root of the `.app`, written after
/// the build and before codesign, so the code signature seals it. Its keys:
///
/// | Key | Value |
/// |---|---|
/// | `Version` | `1` |
/// | `KeyID` | identifies the key in the store's ledger |
/// | `SigningKey` | base64 of the raw 32-byte Ed25519 private key |
/// | `UploadURL` | where traces are POSTed (optional) |
/// | `CommandToken` | bearer token the debug server demands (optional) |
///
/// **What the signature proves.** The private key is in the IPA in plain
/// text, and the store serves IPAs to anything on the tailnet. So a valid
/// signature means "made by a build this store produced, and exactly which
/// one", not "from a genuine device". Apple's App Attest would prove the
/// latter, but it needs an explicit App ID with the capability, and most of
/// these apps sign with the wildcard development profile.
public struct DebugTraceCredential: Sendable {
    public static let filename = "DebugTraceCredential.plist"

    public let keyId: String
    public let uploadURL: URL?
    public let commandToken: String?
    private let signingKeyRaw: Data

    public init(keyId: String, signingKey: Data, uploadURL: URL? = nil, commandToken: String? = nil) throws {
        // Validate now, so a malformed plist fails at load rather than at
        // the first signature.
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        self.keyId = keyId
        self.signingKeyRaw = signingKey
        self.uploadURL = uploadURL
        self.commandToken = commandToken
    }

    /// Reads the bundle's credential, or nil when there is none — an Xcode
    /// build, a TestFlight build, any build that didn't pass through
    /// build-and-sign. Traces from those are still produced, unsigned.
    public static func load(from bundle: Bundle = .main) -> DebugTraceCredential? {
        guard let url = bundle.url(forResource: "DebugTraceCredential", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? parse(plist: data)
    }

    public static func parse(plist data: Data) throws -> DebugTraceCredential {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (dictionary["Version"] as? Int) == 1,
              let keyId = dictionary["KeyID"] as? String, !keyId.isEmpty,
              let keyText = dictionary["SigningKey"] as? String,
              let key = Data(base64Encoded: keyText) else {
            throw DebugError(.invalidArgument, "\(filename) is not a version-1 credential")
        }
        let uploadURL = (dictionary["UploadURL"] as? String).flatMap(URL.init(string:))
        let token = (dictionary["CommandToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return try DebugTraceCredential(keyId: keyId, signingKey: key, uploadURL: uploadURL, commandToken: token)
    }

    /// Ed25519 signature over `data`, 64 raw bytes.
    public func sign(_ data: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyRaw).signature(for: data)
    }

    /// Raw 32-byte public key, what the store's ledger holds.
    public var publicKey: Data {
        // Validated in init.
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyRaw))?.publicKey.rawRepresentation ?? Data()
    }
}
