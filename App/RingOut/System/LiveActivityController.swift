import ActivityKit
import Foundation

/// Starts, updates and ends the lock-screen Live Activity while audio is live.
final class LiveActivityController {
    private var activity: Activity<LiveSessionAttributes>?
    private var last: LiveSessionAttributes.ContentState?

    func update(running: Bool, show: String, interface: String, state: LiveSessionAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if !running {
            end()
            return
        }
        if activity == nil {
            activity = try? Activity.request(
                attributes: LiveSessionAttributes(showName: show, interfaceName: interface),
                content: .init(state: state, staleDate: nil))
            last = state
            return
        }
        guard state != last, let activity else { return }
        last = state
        // Activity is not Sendable; it is only ever touched from the main actor here.
        nonisolated(unsafe) let a = activity
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        last = nil
        nonisolated(unsafe) let a = activity
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
