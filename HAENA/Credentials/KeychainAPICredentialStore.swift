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
        case errSecUserCanceled, errSecInteractionNotAllowed, errSecAuthFailed:
            return .accessDenied
        default:
            return .unavailable(status: status)
        }
    }
}
