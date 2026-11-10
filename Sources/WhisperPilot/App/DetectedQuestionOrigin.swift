import Foundation

/// The listening run and session that heard a detected question.
struct DetectedQuestionOrigin: Equatable {
    let generation: Int
    let sessionID: SessionID?

    /// Stop and the load safety valve only cancel replies that are already
    /// streaming. A question still being checked is not one of those, so it has
    /// to ask this before it starts an answer.
    func canAnswer(generation: Int, sessionID: SessionID?, isAIPaused: Bool) -> Bool {
        !isAIPaused && generation == self.generation && sessionID == self.sessionID
    }
}
