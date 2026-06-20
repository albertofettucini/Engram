# Releasing Engram

The release is automated by [`.github/workflows/release.yml`](../.github/workflows/release.yml): push a
SemVer tag and it builds the universal CLI binaries, the unsigned app, signs the app archive for
Sparkle, regenerates the appcast, and publishes a GitHub Release with everything attached.

Nothing here needs a paid Apple Developer cert. The app ships **unsigned** (Gatekeeper right-click →
Open). The only secret is the Sparkle EdDSA **private key**, which lives as a CI secret and never enters
the repo or history.

---

## What ships in a release

| Asset | What it is | How users get it |
|---|---|---|
| `Engram-<v>.zip` | the unsigned, universal GUI app | release download |
| `engram-cli-macos-universal.tar.gz` | `engram-mcp` + `engram-capture` (universal) | `brew install` (and direct download) |
| `*.sha256` | checksums | verification |
| `appcast.xml` | the Sparkle feed | the app's "Check for Updates" |

The app's `SUFeedURL` is `releases/latest/download/appcast.xml`, so the newest release always serves the
newest feed. Each appcast item points at its **permanent per-tag** zip URL
(`releases/download/v<x.y.z>/Engram-<x.y.z>.zip`), so older versions keep resolving forever.

Platform floors are intentional, not a bug: the **app** targets **macOS 14+** (`LSMinimumSystemVersion`
in `Info.plist`), the **CLI/library** target **macOS 13+** (`platforms: [.macOS(.v13)]` in
`Package.swift`). The MCP server is the headline feature, so it should reach macOS 13 users too.

---

## One-time setup (manual, gated — do once before the first real release)

1. **Generate the Sparkle EdDSA keypair.** Use the same Sparkle version the workflow pins
   (`SPARKLE_TOOLS_VERSION`, currently `2.6.4`):

   ```sh
   curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz | tar -xJ
   ./bin/generate_keys            # creates the private key in your login Keychain, prints the PUBLIC key
   ```

2. **Embed the public key.** Paste the printed public key into `packaging/Info.plist` →
   `SUPublicEDKey` (replacing the `SET_AT_RELEASE_VIA_generate_keys` placeholder). Commit it — the
   public key is meant to be public.

3. **Add the private key as a CI secret — never commit it.** Export it from the Keychain and add it to
   the repo as the Actions secret **`SPARKLE_ED_PRIVATE_KEY`**:

   ```sh
   ./bin/generate_keys -x sparkle_private_key   # writes the private key to ./sparkle_private_key
   gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key
   rm sparkle_private_key                        # do NOT leave it on disk or in the repo
   ```

4. **Create the Homebrew tap.** A separate repo named **`albertofettucini/homebrew-engram`** with the
   formula at `Formula/engram.rb` (copy of [`packaging/homebrew/engram.rb`](homebrew/engram.rb)). That
   is what makes `brew install albertofettucini/engram/engram` resolve.

> Until step 1–3 are done, tagging still produces a release with the app + CLI, but the workflow logs a
> warning and **skips the appcast** (in-app updates won't be fed). That's fine for `v0.1.0` (no one to
> update yet); do the key setup before `v0.1.1`.

---

## Cutting a release

1. Make sure `main` builds and the version is what you want. The workflow stamps
   `CFBundleShortVersionString` from the tag and `CFBundleVersion` from the git commit count
   (monotonic — required for Sparkle to recognise a newer build), so you don't edit `Info.plist`.

2. Tag and push:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

   The workflow runs and publishes the GitHub Release.

3. **Update the Homebrew formula.** From the release, copy the printed SHA256 of
   `engram-cli-macos-universal.tar.gz` (also attached as `…​.sha256`). In
   `packaging/homebrew/engram.rb` bump `url`, `version`, and `sha256`, then copy the file into the tap
   repo as `Formula/engram.rb` and push. Verify:

   ```sh
   brew install albertofettucini/engram/engram
   engram-mcp --connect
   ```

---

## Anonymity

Everything published — code, metadata, commit history, release notes, the formula, the tap, the
appcast — carries only the persona **Joseph** / `joseph.thecouncil@gmail.com` and the
`albertofettucini` account. Before committing in any clone, set the local identity:

```sh
git config user.name "Joseph"
git config user.email "joseph.thecouncil@gmail.com"
```
