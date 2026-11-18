import Contacts
import Foundation

/// Finding who "Enda" or "mum" is in Contacts, for emails and messages from
/// the launcher. macOS asks once before AgentX can read Contacts.
enum ContactLookup {
    struct Found: Equatable, Sendable {
        var name: String
        /// An email address or a phone number.
        var address: String
    }

    /// `who` as an address: itself if it already is one, otherwise the first match in Contacts.
    static func find(_ who: String, wantPhone: Bool) async -> Found? {
        let w = who.trimmingCharacters(in: .whitespacesAndNewlines)
        if w.contains("@") { return Found(name: w, address: w) }
        if w.filter(\.isNumber).count >= 6, w.allSatisfy({ $0.isNumber || "+ -()".contains($0) }) { return Found(name: w, address: w) }
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Found? in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                        CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: w), keysToFetch: keys)) ?? []
            for c in contacts {
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let display = name.isEmpty ? (c.nickname.isEmpty ? c.organizationName : c.nickname) : name
                if wantPhone, let phone = c.phoneNumbers.first?.value.stringValue { return Found(name: display, address: phone) }
                if let email = c.emailAddresses.first?.value as String? { return Found(name: display, address: email) }
                if let phone = c.phoneNumbers.first?.value.stringValue { return Found(name: display, address: phone) }
            }
            return nil
        }.value
    }
}
