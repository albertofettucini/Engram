import Foundation
import NaturalLanguage

/// A REAL on-device embedder using Apple's built-in NaturalLanguage word embeddings — no model
/// download, no network, no Python. A sentence vector = the mean of its word vectors, L2-normalized.
/// This lets the app ship with NO network entitlement TODAY (the privacy claim) without bundling a
/// model. It's weaker than a transformer; a Core ML all-MiniLM provider behind the same protocol is
/// the planned quality upgrade. Falls back to the deterministic HashingEmbedder when the OS word
/// model is unavailable or the text is entirely out-of-vocabulary, so recall never silently breaks.
public struct NLEmbeddingProvider: EmbeddingProvider {
    private let embedding: NLEmbedding?
    public let dimension: Int
    private let fallback: HashingEmbedder

    public init(language: NLLanguage = .english, fallbackDimension: Int = 256) {
        let emb = NLEmbedding.wordEmbedding(for: language)
        self.embedding = emb
        let dim = emb?.dimension ?? fallbackDimension
        self.dimension = dim
        self.fallback = HashingEmbedder(dimension: dim)
    }

    public func embed(_ text: String) -> [Float] {
        guard let embedding else { return fallback.embed(text) }
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var counted = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            if let vec = embedding.vector(for: word) {
                for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
                counted += 1
            }
        }
        guard counted > 0 else { return fallback.embed(text) }   // OOV-only → keep recall working
        var out = [Float](repeating: 0, count: embedding.dimension)
        var norm: Float = 0
        for i in sum.indices {
            let v = Float(sum[i] / Double(counted))
            out[i] = v
            norm += v * v
        }
        norm = norm.squareRoot()
        if norm > 0 { for i in out.indices { out[i] /= norm } }
        return out
    }
}
