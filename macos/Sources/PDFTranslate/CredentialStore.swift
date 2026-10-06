import Foundation
import Security
import CryptoKit

protocol CredentialStoring {
    func read(account: String) throws -> String?
    func write(_ key: String, account: String) throws
    func delete(account: String) throws
}

/// Stores that may block on system authorization expose asynchronous operations.
/// In-memory stores can keep the synchronous protocol for deterministic tests.
protocol AsyncCredentialStoring: CredentialStoring {
    func read(account: String, allowAuthentication: Bool) async throws -> String?
    func writeAsync(_ key: String, account: String) async throws
    func deleteAsync(account: String) async throws
}

protocol LegacyCredentialReading {
    func readLegacy(account: String) async throws -> String?
}

enum CredentialAccessError: LocalizedError {
    case authorizationRequired, unreadableKeyCannotBeDeleted, timedOut
    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return L10n.text("To use a saved API key, choose Load Saved Key and approve the macOS prompt, or enter a new key.")
        case .unreadableKeyCannotBeDeleted:
            return L10n.text("Load your saved API key before clearing it. The saved key has not been changed.")
        case .timedOut:
            return L10n.text("Keychain access timed out. You can try again or enter a new API key.")
        }
    }
}

/// Security's synchronous read cannot be interrupted once it starts. Stop awaiting it
/// on cancellation/deadline, discard its late result, and leave writes on their own queue.
enum CredentialReadScheduler {
    private static let readQueue = DispatchQueue(label: "org.pdfmathtranslate.next.keychain.read",
                                                qos: .userInitiated, attributes: .concurrent)

    static func perform<Value>(timeout: TimeInterval = 30, queue: DispatchQueue? = nil,
                               _ operation: @escaping () throws -> Value) async throws -> Value {
        let state = CredentialReadState<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let deadline = DispatchWorkItem { [weak state] in
                    state?.complete(.failure(CredentialAccessError.timedOut))
                }
                if state.installDeadline(deadline) {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
                }
                (queue ?? readQueue).async {
                    // A cancelled read still waiting for a queue slot must not request authorization.
                    guard state.begin() else { return }
                    state.complete(Result { try operation() })
                }
            }
        } onCancel: {
            state.complete(.failure(CancellationError()))
        }
    }
}

private final class CredentialReadState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var earlyResult: Result<Value, Error>?
    private var deadline: DispatchWorkItem?
    private var finished = false
    private var started = false

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result = earlyResult {
            earlyResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installDeadline(_ deadline: DispatchWorkItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        self.deadline = deadline
        return true
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !started else { return false }
        started = true
        return true
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { earlyResult = result }
        let deadline = deadline
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        continuation?.resume(with: result)
    }
}

struct KeychainCredentialStore: AsyncCredentialStoring, LegacyCredentialReading {
    private static let mutationQueue = DispatchQueue(label: "org.pdfmathtranslate.next.keychain.write", qos: .userInitiated)
    static let legacyService = "org.pdfmathtranslate.next.desktop.api-key"
    private let service = ReleaseInfo.current.keychainService
    private func query(_ account: String, service: String? = nil) -> [String: Any] {
        let hashed = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service,
                kSecAttrAccount as String: hashed]
    }
    func read(account: String) throws -> String? {
        // Legacy macOS file-keychain items may ignore per-query UI suppression.
        // Never decrypt a secret from a passive or synchronous UI read.
        throw CredentialAccessError.authorizationRequired
    }
    func read(account: String, allowAuthentication: Bool) async throws -> String? {
        guard allowAuthentication else { throw CredentialAccessError.authorizationRequired }
        return try await CredentialReadScheduler.perform { try readAuthorized(account: account) }
    }
    func writeAsync(_ key: String, account: String) async throws {
        try await Self.perform { try write(key, account: account) }
    }
    func deleteAsync(account: String) async throws {
        try await Self.perform { try delete(account: account) }
    }
    // Only the explicit import action may access the old service. Never mutate it.
    func readLegacy(account: String) async throws -> String? {
        try await CredentialReadScheduler.perform {
            try readAuthorized(account: account, service: Self.legacyService)
        }
    }
    private func readAuthorized(account: String, service: String? = nil) throws -> String? {
        var query = query(account, service: service)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw failure(errSecDecode) }
        return key
    }
    private static func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            // Mutations report actual Security completion; a timeout must not imply rollback.
            mutationQueue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
    func write(_ key: String, account: String) throws {
        let query = query(account)
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: L10n.text("Could not access Keychain. Unlock your login keychain and try again.")])
    }
}
