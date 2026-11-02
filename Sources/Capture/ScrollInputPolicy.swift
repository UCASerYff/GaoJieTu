import Foundation
import CoreGraphics

/// Pure input selection and attempt accounting. No AX, event creation, permission request or input occurs here.
struct ScrollInputPolicy {
    enum Capability: Equatable { case advertised, absent, unknown }
    enum Strategy: Int { case native = 1, pixel = 2 }
    enum Failure: Error, Equatable { case noCandidate, unknownCapability, invalidPixelBudget, capabilityChanged, inputAlreadyAttempted, postingUnavailable }
    struct Candidate {
        let plan: ScrollVisibilityPlan
        let capability: Capability
    }
    struct Decision: Equatable {
        let index: Int
        let strategy: Strategy
        let pixels: Int32
    }

    /// One logical transaction. A prepared hover can lead to one wheel, never a new input strategy.
    struct Attempt {
        enum State: Int {
            case unused = 0, nativeAttempted, ownPrimed, wheelAttempted, refused
        }
        private(set) var state = State.unused
        private var originalDecision: Decision?

        init() {}

        /// Advance immediately before the native action or PID-bound preparatory event is posted.
        mutating func begin(decision: Decision, freshCapability: Capability, postingAvailable: Bool) throws {
            do {
                guard state == .unused else { throw Failure.inputAlreadyAttempted }
                try ScrollInputPolicy.requireReady(decision, freshCapability: freshCapability,
                    inputAlreadyAttempted: state != .unused, postingAvailable: postingAvailable)
                originalDecision = decision
                state = decision.strategy == .native ? .nativeAttempted : .ownPrimed
            } catch {
                refuse()
                throw error
            }
        }

        /// Called only after all original-source guards have been checked again following the prime.
        mutating func beginWheel(decision: Decision, freshCapability: Capability, postingAvailable: Bool) throws {
            do {
                guard state == .ownPrimed else { throw Failure.inputAlreadyAttempted }
                guard originalDecision == decision, decision.strategy == .pixel,
                      freshCapability == .absent else { throw Failure.capabilityChanged }
                guard decision.pixels >= 1, postingAvailable else { throw Failure.postingUnavailable }
                state = .wheelAttempted
            } catch {
                refuse()
                throw error
            }
        }

        /// A failed guard, cancellation or expired deadline permanently consumes this transaction.
        mutating func refuse() { state = .refused }
    }

    static func select(_ candidates: [Candidate], requestedPoints: CGFloat) throws -> Decision {
        guard !candidates.isEmpty else { throw Failure.noCandidate }
        // A verified native candidate wins; unrelated unknown capabilities cannot authorize CG.
        if let index = candidates.indices.filter({ candidates[$0].capability == .advertised })
            .min(by: { candidates[$0].plan.expectedMinimumScroll < candidates[$1].plan.expectedMinimumScroll }) {
            return Decision(index: index, strategy: .native, pixels: 0)
        }
        // With no verified native choice, unknown evidence is never proof of absence.
        guard !candidates.contains(where: { $0.capability == .unknown }) else { throw Failure.unknownCapability }
        guard let index = candidates.indices.min(by: { candidates[$0].plan.expectedMinimumScroll < candidates[$1].plan.expectedMinimumScroll }) else {
            throw Failure.noCandidate
        }
        let plan = candidates[index].plan
        let amount = floor(min(240, requestedPoints, plan.roi.height * 0.5))
        guard requestedPoints.isFinite, requestedPoints > 0, requestedPoints <= 2_000,
              amount.isFinite, amount >= 1, amount <= plan.stepBudget, amount >= plan.expectedMinimumScroll else { throw Failure.invalidPixelBudget }
        return Decision(index: index, strategy: .pixel, pixels: Int32(amount))
    }

    static func requireReady(_ decision: Decision, freshCapability: Capability,
                             inputAlreadyAttempted: Bool, postingAvailable: Bool) throws {
        guard !inputAlreadyAttempted else { throw Failure.inputAlreadyAttempted }
        let expected: Capability = decision.strategy == .native ? .advertised : .absent
        guard freshCapability == expected else { throw Failure.capabilityChanged }
        if decision.strategy == .pixel {
            guard decision.pixels >= 1, postingAvailable else { throw Failure.postingUnavailable }
        }
    }
}
