import Foundation

/// Decisions only: no HAL, task scheduling, or recording commands. A supplied monotonic time
/// makes the grace rules testable and keeps wall-clock adjustments out of recording policy.
struct AutoRecordPolicy {
    enum Decision: Equatable {
        case none
        case start(String)
        case stop(ownerActiveSeconds: TimeInterval)
    }

    static let grace: TimeInterval = 20
    private(set) var restrictedOwners: Set<String> = []
    private var absentSince: [String: TimeInterval] = [:]
    private var ownerGoneSince: TimeInterval?
    private var waitingForQuiet = false
    private var quietSince: TimeInterval?

    mutating func restrict(_ owners: Set<String>?) {
        // A Stop before this session's first read, or during a failed/pending read, has no complete
        // owner set. Wait for confirmed quiet instead of undoing Stop or using an old snapshot
        // that could omit another participant in the same mic activity.
        guard let owners else {
            waitingForQuiet = true
            quietSince = nil
            recordingChanged()
            return
        }
        // A later deliberate Stop with known owners replaces the earlier uncertainty. Otherwise
        // even a new, unrelated app could remain blocked after the user manually records again.
        waitingForQuiet = false
        quietSince = nil
        restrictedOwners.formUnion(owners)
        for owner in owners { absentSince[owner] = nil }
        recordingChanged()
    }

    mutating func recordingChanged() { ownerGoneSince = nil }

    mutating func evaluate(
        owners: Set<String>?, eligible: Set<String>, canStart: Bool,
        detectedAt: TimeInterval?, now: TimeInterval
    ) -> Decision {
        guard let owners else {
            // Unknown time cannot count as proof of absence, including for lifting a Stop.
            absentSince.removeAll()
            ownerGoneSince = nil
            quietSince = nil
            return .none
        }
        if waitingForQuiet {
            if eligible.isEmpty {
                let since = quietSince ?? now
                quietSince = since
                if now - since >= Self.grace { waitingForQuiet = false; quietSince = nil }
            } else {
                quietSince = nil
            }
        }
        for owner in restrictedOwners {
            if owners.contains(owner) {
                absentSince[owner] = nil
            } else {
                let since = absentSince[owner] ?? now
                absentSince[owner] = since
                if now - since >= Self.grace {
                    restrictedOwners.remove(owner)
                    absentSince[owner] = nil
                }
            }
        }
        if let detectedAt {
            guard eligible.isEmpty else {
                ownerGoneSince = nil
                return .none
            }
            let since = ownerGoneSince ?? now
            ownerGoneSince = since
            if now - since >= Self.grace {
                return .stop(ownerActiveSeconds: max(0, since - detectedAt))
            }
        } else {
            ownerGoneSince = nil
            if canStart, !waitingForQuiet, let owner = eligible.subtracting(restrictedOwners).sorted().first {
                return .start(owner)
            }
        }
        return .none
    }
}

/// The manual-recording nudge shares the same definition of a trustworthy absence, but never
/// owns stopping. Resetting it on a settings change avoids claiming a checkbox ended a call.
struct CallOwnerNudge {
    private var hadOwner = false
    private var goneSince: TimeInterval?
    private var notified = false

    mutating func observe(_ owners: Set<String>?, now: TimeInterval) -> Bool {
        guard !notified else { return false }
        guard let owners else { goneSince = nil; return false }
        if !owners.isEmpty { hadOwner = true; goneSince = nil; return false }
        guard hadOwner else { return false }
        let since = goneSince ?? now
        goneSince = since
        guard now - since >= 3 else { return false }
        notified = true
        return true
    }
}
