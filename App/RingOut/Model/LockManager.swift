import CryptoKit
import Foundation

/// PIN lock for rental and volunteer hand-off. Only a salted SHA-256 hash is stored.
enum LockPIN {
    private static let salt = "ringout.lock.v1:"

    static func hash(_ pin: String) -> String {
        let digest = SHA256.hash(data: Data((salt + pin).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ pin: String, hash: String?) -> Bool {
        guard let hash else { return true }
        return Self.hash(pin) == hash
    }

    static func isValid(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy(\.isNumber)
    }
}
