import Foundation
import NaturalLanguage

/// The quality upgrade over `NLEmbeddingProvider`: Apple's built-in TRANSFORMER sentence embeddings
/// (`NLContextualEmbedding`, macOS 14+). Contextual — "bank" near "river" vs "money" gets different
/// vectors — so recall is meaningfully better than averaging static word vectors. Still on-device,
/// still no Python, still no model file to bundle (the OS owns the asset).
///
/// Privacy contract (the brand's spine — "this app has no internet access"):
///   • By DEFAULT this provider uses the contextual model ONLY if its assets are ALREADY on the
///     machine. If they aren't, it silently falls back to `NLEmbeddingProvider` — it never reaches
///     the network. So the "no network entitlement" claim stays literally true out of the box.
///   • Fetching the asset is a DELIBERATE, opt-in, one-time step (`ENGRAM_EMBED_DOWNLOAD=1`, or
///     `engram-mcp --prepare-embeddings`). After that one fetch, every run uses the better model
///     with ZERO runtime network.
///
/// A whole process commits to one mode at init (contextual OR fallback), so every vector it produces
/// has the same dimension — `cosineSimilarity` (which guards on equal length) stays valid.
public struct NLContextualEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int
    private let useContextual: Bool
    private let fallback: NLEmbeddingProvider

    /// - Parameter downloadIfNeeded: when the contextual asset is missing, block once to fetch it
    ///   (network). Defaults to OFF unless `ENGRAM_EMBED_DOWNLOAD=1` — so the app never freezes its
    ///   UI on a download and never silently phones home.
    public init(downloadIfNeeded: Bool = ProcessInfo.processInfo.environment["ENGRAM_EMBED_DOWNLOAD"] == "1",
                fallback: NLEmbeddingProvider = NLEmbeddingProvider()) {
        self.fallback = fallback
        if #available(macOS 14.0, *), let model = ContextualEmbeddingModel.shared(downloadIfNeeded: downloadIfNeeded) {
            self.useContextual = true
            self.dimension = model.dimension
        } else {
            self.useContextual = false
            self.dimension = fallback.dimension
        }
    }

    public func embed(_ text: String) -> [Float] {
        if useContextual, #available(macOS 14.0, *), let model = ContextualEmbeddingModel.shared(downloadIfNeeded: false) {
            if let v = model.vector(for: text) { return v }
            // Active in contextual mode but this string yielded no tokens. A zero vector would make this
            // memory permanently unrecallable; instead fall back to a SAME-DIMENSION lexical hash so it
            // stays matchable (and keeps every vector the same length, so cosine stays valid).
            return HashingEmbedder(dimension: dimension).embed(text)
        }
        return fallback.embed(text)
    }

    /// Deliberate, one-time asset fetch (the only path that may touch the network). Returns a short
    /// human-readable status. Used by `engram-mcp --prepare-embeddings`.
    @discardableResult
    public static func prepare() -> String {
        guard #available(macOS 14.0, *) else {
            return "Contextual embeddings need macOS 14+. Staying on the built-in word embedder."
        }
        return ContextualEmbeddingModel.download()
    }
}

// MARK: - Shared loader

/// Process-wide, loaded at most once (the app's `reload()` re-creates the engine often; loading the
/// transformer every time would be wasteful). Decides ONCE whether contextual embeddings are usable.
@available(macOS 14.0, *)
final class ContextualEmbeddingModel {
    let embedding: NLContextualEmbedding
    let dimension: Int

    private static let lock = NSLock()
    private static var instance: ContextualEmbeddingModel?
    private static var resolved = false   // we tried once and decided (success or not)

    private init(embedding: NLContextualEmbedding) {
        self.embedding = embedding
        self.dimension = embedding.dimension
    }

    /// Returns the loaded model, or nil if the asset isn't present (and we weren't asked to fetch it).
    /// Latin-script model → covers English AND Turkish (the primary languages it's used with).
    static func shared(downloadIfNeeded: Bool) -> ContextualEmbeddingModel? {
        lock.lock(); defer { lock.unlock() }
        if let i = instance { return i }
        if resolved && !downloadIfNeeded { return nil }   // already decided "no" — don't keep retrying

        guard let e = NLContextualEmbedding(script: .latin) else { resolved = true; return nil }
        var haveAssets = e.hasAvailableAssets
        if !haveAssets && downloadIfNeeded { haveAssets = blockingRequestAssets(e) }
        guard haveAssets, (try? e.load()) != nil else { resolved = true; return nil }

        let model = ContextualEmbeddingModel(embedding: e)
        instance = model
        resolved = true
        return model
    }

    /// Mean-pooled token vectors, L2-normalized. nil when the text produced no tokens.
    func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let result = try? embedding.embeddingResult(for: trimmed, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vec, _ in
            for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        var out = [Float](repeating: 0, count: dimension)
        var norm: Float = 0
        for i in 0..<dimension {
            let v = Float(sum[i] / Double(count))
            out[i] = v
            norm += v * v
        }
        norm = norm.squareRoot()
        if norm > 0 { for i in out.indices { out[i] /= norm } }
        return out
    }

    /// Explicit one-time fetch. Status string is for the CLI.
    static func download() -> String {
        guard let e = NLContextualEmbedding(script: .latin) else {
            return "No Latin-script contextual model on this OS. Staying on the built-in word embedder."
        }
        if e.hasAvailableAssets {
            return "Contextual embedding model already present — Engram will use it. (dimension \(e.dimension))"
        }
        return blockingRequestAssets(e)
            ? "Downloaded the contextual embedding model. Engram will now use it (no network at runtime)."
            : "Could not fetch the contextual model (offline or unavailable). Engram keeps using the built-in word embedder — nothing breaks."
    }

    /// Wraps the async asset request into a bounded blocking call. Only ever reached on the explicit
    /// opt-in path, so blocking here is fine.
    private static func blockingRequestAssets(_ e: NLContextualEmbedding) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        e.requestAssets { result, _ in
            ok = (result == .available)
            sem.signal()
        }
        // Generous: the OS download can be slow. Time out rather than hang forever.
        _ = sem.wait(timeout: .now() + 180)
        return ok && e.hasAvailableAssets
    }
}
