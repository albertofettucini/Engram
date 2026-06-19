# Privacy

Engram is **local-first by design**. No account, no server, no telemetry, no analytics.

- Your memories live on your Mac as plain **`.md` files you own** — open them in any editor, grep them, back them up, delete them. Nothing is hidden in a binary blob or a cloud.
- Your **memories never leave your Mac** — Engram never uploads your data, with no exceptions.

## Don't take our word for it — verify

Engram is open source, so you can check the claim yourself instead of trusting it:

- **The app does no networking of its own** — and never connects automatically. Its own source contains no networking code; verify it:

  ```sh
  grep -rnE "URLSession|URLRequest|dataTask|https?://" Sources/engram-app/
  # → no matches (the app makes no network calls of its own)
  ```

- The network is touched only by **opt-in, clearly-labeled actions** — and **none of them send your data**:
  - **Check for Updates** (the button in Settings) — a *manual*, user-initiated check via [Sparkle](https://sparkle-project.org). It fetches a small version file ("appcast") to ask *"is there a newer Engram?"* — nothing about you is sent. Automatic background checks are **off**, so the app stays silent on the network until you click it.
  - **Local Ollama distiller** (`engram-capture --ollama`) — talks to a model on `localhost`; never leaves your Mac. Off by default.
  - **On-device embedding model** (`engram-mcp --prepare-embeddings`, or `ENGRAM_EMBED_DOWNLOAD=1`) — a one-time download of Apple's on-device model. Off by default; once present, recall runs with zero network.

Your **memories** are never part of any of these. Everything else is local file I/O and on-device computation.

## What about API keys / secrets?

There are none to leak — Engram never authenticates to any service and stores no account secret. (The update check verifies each download against a public signing key baked into the app; there's no private key or credential on your side.)

## Roadmap

A future hardened build may run under the macOS App Sandbox so the OS itself enforces the boundaries above — any network access scoped to the opt-in paths (updates, optional localhost model), and your memories never leaving the Mac becoming an OS guarantee rather than something you verify. (It needs an app-group change to keep the shared on-disk store working, so it's a deliberate, tested step rather than a default.)
