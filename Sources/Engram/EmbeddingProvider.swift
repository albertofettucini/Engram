import Foundation

/// Turns text into a vector for semantic recall. The shipping default will be an on-device
/// Core ML embedder (all-MiniLM) behind this same protocol — that's what lets the app run with
/// NO network entitlement and make the "this app has no internet access" privacy claim.
public protocol EmbeddingProvider {
    var dimension: Int { get }
    func embed(_ text: String) -> [Float]
}

/// Cosine similarity. Providers return L2-normalized vectors, so this is just the dot product.
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    for i in a.indices { dot += a[i] * b[i] }
    return dot
}

/// Deterministic, dependency-free DEV embedder: signed-hashes word unigrams+bigrams into a fixed
/// vector. NOT semantically strong — it exists so the whole store → recall → eval pipeline is
/// runnable and testable TODAY, before the Core ML model is wired in. Swap it via the protocol.
public struct HashingEmbedder: EmbeddingProvider {
    public let dimension: Int
    public init(dimension: Int = 256) { self.dimension = dimension }

    public func embed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for token in Self.tokens(text) {
            let h = Self.fnv1a(token)
            let idx = Int(h % UInt64(dimension))
            let sign: Float = (h & 1) == 0 ? 1 : -1   // signed hashing reduces collision bias
            v[idx] += sign
        }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }

    static func tokens(_ text: String) -> [String] {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out = words
        if words.count > 1 {
            for i in 0..<(words.count - 1) { out.append(words[i] + "_" + words[i + 1]) }
        }
        return out
    }

    /// FNV-1a — deterministic across processes (Swift's Hasher is per-process randomized).
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
