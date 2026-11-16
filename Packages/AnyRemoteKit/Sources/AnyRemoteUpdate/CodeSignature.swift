import Foundation
import Security

/// Checks that an update is signed by whoever signed the running app.
///
/// AnyRemote releases are signed with a self-signed certificate that only
/// the release Mac holds, so the running app's designated requirement
/// (`identifier … and certificate leaf = H"…"`) admits releases from that
/// Mac and nothing else. An ad-hoc signed build (development) has no such
/// requirement and can't be updated.
public enum CodeSignature {
    /// The running app's designated requirement, or nil when it is ad-hoc
    /// signed or unsigned.
    public static func runningAppRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return requirement(of: staticCode)
    }

    /// The designated requirement of the bundle at `url`, nil when ad-hoc.
    public static func requirement(ofBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        return requirement(of: staticCode)
    }

    private static func requirement(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        // kSecCodeSignatureAdhoc: the requirement would be a cdhash, which no
        // other build satisfies.
        guard flags & 0x2 == 0, info[kSecCodeInfoCertificates as String] != nil else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    /// Throws unless the bundle's signature is intact (every architecture and
    /// nested helper) and satisfies `requirement`.
    public static func verify(bundleAt url: URL, satisfies requirement: String) throws {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { throw UpdateError.signature("invalid requirement") }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.signature("not code")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, compiled, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
            throw UpdateError.signature(detail)
        }
    }
}
