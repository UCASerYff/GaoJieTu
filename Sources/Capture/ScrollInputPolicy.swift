import Foundation
import CoreGraphics

/// Pure input selection only. No AX, CG event creation, permission request or input occurs here.
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
