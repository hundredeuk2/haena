import Foundation
import Security

/// The real credential store: a single generic-password item in the user's login Keychain.
///
/// The Keychain rather than UserDefaults, a JSON file, or anything else the app already writes —
/// those are all readable by anything that can read the user's home directory, and two of them
/// (`projects.json`, `profile.json`) are files a user might reasonably copy or share. A key belongs
/// somewhere that stays behind.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the app needs the key while it runs, never
/// before first unlock, and the item must not travel to another machine in a backup.
struct KeychainAPICredentialStore: APICredentialStore {
    private let service: String
    private let account: String

    init(
        service: String = CredentialItem.service,
        account: String = CredentialItem.Account.openAI
    ) {
        self.service = service
        self.account = account
    }

    func credential() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let text = String(data: data, encoding: .utf8) else {
                // Present but unreadable — treat as absent rather than crashing or guessing.
                return nil
            }
            return CredentialNormalisation.normalised(text)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.mapped(status)
        }
    }

    /// The same item, read in a way that never asks macOS to put a window on screen.
    ///
    /// Two steps, because one query cannot distinguish the two answers a caller must tell apart.
    /// `kSecUseAuthenticationUISkip` *silently skips* items that would need UI, so the read alone
    /// reports `errSecItemNotFound` both for "no key saved" and for "a key is saved but locked
    /// behind a prompt". Sending the user to re-enter a key they already have would be the wrong
    /// advice, so presence is established first, with an attributes-only query that has no secret
    /// to decrypt and therefore nothing to authenticate for.
    ///
    /// This is best effort by contract, not by oversight. `SecItem.h` states that on macOS the
    /// no-UI attributes apply to Data Protection keychain items and that "legacy keychain items
    /// will still activate UI if needed" — and this item is a legacy one. `OpenAICredentialResolver`
    /// therefore treats a call that does not return promptly as `interactionRequired` too; this
    /// method narrows the window rather than closing it.
    func credentialWithoutInteraction() throws -> String? {
        var presence = baseQuery()
        presence[kSecReturnAttributes as String] = true
        presence[kSecMatchLimit as String] = kSecMatchLimitOne
        presence[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var presenceResult: CFTypeRef?
        switch SecItemCopyMatching(presence as CFDictionary, &presenceResult) {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        case let status:
            throw Self.mapped(status)
        }

        var read = baseQuery()
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        read[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return CredentialNormalisation.normalised(text)
        case errSecItemNotFound:
            // Present a moment ago, absent now that the secret itself is being asked for: the item
            // was skipped because reading it needs the user.
            throw CredentialStoreError.interactionRequired
        case let status:
            throw Self.mapped(status)
        }
    }

    func save(_ credential: String) throws {
        guard let normalised = CredentialNormalisation.normalised(credential) else {
            throw CredentialStoreError.blankCredential
        }
        guard let data = normalised.data(using: .utf8) else {
            throw CredentialStoreError.blankCredential
        }

        // Update first: adding over an existing item is what produces duplicates, and a duplicate
        // means a later read can return whichever the Keychain happens to hand back.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw Self.mapped(updateStatus)
        }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Raced with another writer between the update and the add; the update path is correct
            // now that the item exists.
            let retry = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retry == errSecSuccess else {
                throw Self.mapped(retry)
            }
        default:
            throw Self.mapped(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            // Already gone is the outcome the caller asked for.
            return
        default:
            throw Self.mapped(status)
        }
    }

    // MARK: - Private

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Separates "the user said no" from "the Keychain is broken", because only one of those is
    /// worth showing as an error. The status code is carried; the item never is.
    static func mapped(_ status: OSStatus) -> CredentialStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired:
            // The Keychain is saying "I would have to ask the user". That is a different
            // instruction to the caller than "the user said no", which is why it stopped being
            // folded into `accessDenied`.
            return .interactionRequired
        case errSecUserCanceled, errSecAuthFailed:
            return .accessDenied
        default:
            return .unavailable(status: status)
        }
    }
}
