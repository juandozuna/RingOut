import Foundation
import Observation
import StoreKit

/// App Store entitlement. Pro = 2 channels and every feature; Trial = 1 channel
/// with a 2 s mute every 90 s. Receipt validation is local (StoreKit 2), so it
/// works offline and survives device swaps under the same Apple ID.
@Observable
final class License {
    static let proProductID = "com.juandozuna.ringout.pro"

    private(set) var isPro = false
    private(set) var product: Product?
    private(set) var statusText = "Checking…"
    private(set) var purchasing = false
    /// Development builds unlock Pro so the full app can be tested without App Store Connect.
    let developmentUnlock: Bool

    init() {
        #if DEBUG
        developmentUnlock = true
        #else
        developmentUnlock = false
        #endif
        if developmentUnlock {
            isPro = true
            statusText = "Pro (development build)"
        }
        Task { await refresh() }
        Task { await listen() }
    }

    func refresh() async {
        product = try? await Product.products(for: [Self.proProductID]).first
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.proProductID, t.revocationDate == nil { owned = true }
        }
        apply(owned: owned)
    }

    private func listen() async {
        for await result in Transaction.updates {
            if case .verified(let t) = result {
                await t.finish()
                await refresh()
            }
        }
    }

    private func apply(owned: Bool) {
        if owned {
            isPro = true
            statusText = "Pro — purchased"
        } else if developmentUnlock {
            isPro = true
            statusText = "Pro (development build)"
        } else {
            isPro = false
            statusText = "Trial — 1 channel, 2 s mute every 90 s"
        }
    }

    func purchase() async {
        guard let product else { return }
        purchasing = true
        defer { purchasing = false }
        if case .success(let verification) = try? await product.purchase(), case .verified(let t) = verification {
            await t.finish()
            await refresh()
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
