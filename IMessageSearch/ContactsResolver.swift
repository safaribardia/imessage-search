import Contacts
import Foundation

@MainActor
final class ContactsResolver: ObservableObject {
    static let shared = ContactsResolver()

    @Published private(set) var map = HandleNameMap(names: [:])
    @Published private(set) var meName = NSFullUserName()
    @Published private(set) var meThumbnail: Data?
    @Published private(set) var authorizationStatus =
        CNContactStore.authorizationStatus(for: .contacts)
    private var hasLoaded = false

    func refreshAuthorizationStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    @discardableResult
    func requestAccess() async -> Bool {
        let granted = await Self.requestContactsAccess()
        refreshAuthorizationStatus()
        if granted {
            await loadAuthorizedContacts()
        }
        return granted
    }

    func loadIfAuthorized() async {
        refreshAuthorizationStatus()
        guard authorizationStatus == .authorized else {
            return
        }
        await loadAuthorizedContacts()
    }

    private func loadAuthorizedContacts() async {
        guard !hasLoaded else {
            return
        }
        map = await Self.fetchMap()
        if let me = await Self.fetchMe() {
            meName = me.name
            meThumbnail = me.thumbnail
        }
        hasLoaded = true
    }

    private nonisolated static func requestContactsAccess() async -> Bool {
        let store = CNContactStore()
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    private nonisolated static func fetchMe() async -> (name: String, thumbnail: Data?)? {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactThumbnailImageDataKey,
        ] as [CNKeyDescriptor]
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else {
            return nil
        }
        let name = "\(me.givenName) \(me.familyName)"
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return nil
        }
        return (name, me.thumbnailImageData)
    }

    private nonisolated static func fetchMap() async -> HandleNameMap {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactThumbnailImageDataKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var names: [String: String] = [:]
        var thumbnails: [String: Data] = [:]
        try? store.enumerateContacts(with: request) { contact, _ in
            var name = "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                name = contact.organizationName
            }
            guard !name.isEmpty else {
                return
            }

            var keys: [String] = []
            for phone in contact.phoneNumbers {
                let digits = phone.value.stringValue.filter(\.isNumber)
                guard digits.count >= 7 else {
                    continue
                }
                keys.append(digits)
                keys.append(String(digits.suffix(10)))
            }
            for email in contact.emailAddresses {
                keys.append((email.value as String).lowercased())
            }

            for key in keys {
                names[key] = name
                if let thumbnail = contact.thumbnailImageData {
                    thumbnails[key] = thumbnail
                }
            }
        }
        return HandleNameMap(names: names, thumbnails: thumbnails)
    }
}
