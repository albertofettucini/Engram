import Foundation

/// Recall quality is the product: if recall feels flaky, native polish is worthless. This harness
/// makes it MEASURABLE — a labelled set of (query → the memory that should come back) lets us put a
/// number on recall and compare embedding swaps (HashingEmbedder vs Core ML) apples to apples.

public struct EvalCase {
    public let query: String
    public let expectedMemoryID: UUID
    public init(query: String, expectedMemoryID: UUID) {
        self.query = query
        self.expectedMemoryID = expectedMemoryID
    }
}

public struct EvalCaseResult {
    public let query: String
    public let hit: Bool
    public let rank: Int?   // 1-based rank of the expected memory within top-k; nil = missed
}

public struct EvalResult {
    public let hitRateAtK: Double   // fraction of queries whose expected memory was in the top k
    public let hits: Int
    public let total: Int
    public let k: Int
    public let perCase: [EvalCaseResult]
}

public func evaluateRecall(_ index: MemoryIndex,
                           cases: [EvalCase],
                           k: Int = 5,
                           scope: RecallScope = .all) -> EvalResult {
    var hits = 0
    var perCase: [EvalCaseResult] = []
    for c in cases {
        let results = index.recall(c.query, scope: scope, k: k)
        let idx = results.firstIndex { $0.memory.id == c.expectedMemoryID }
        if idx != nil { hits += 1 }
        perCase.append(EvalCaseResult(query: c.query, hit: idx != nil, rank: idx.map { $0 + 1 }))
    }
    let rate = cases.isEmpty ? 0 : Double(hits) / Double(cases.count)
    return EvalResult(hitRateAtK: rate, hits: hits, total: cases.count, k: k, perCase: perCase)
}
