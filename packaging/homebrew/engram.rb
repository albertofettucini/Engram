# Engram Homebrew formula — STAGING COPY.
#
# The live formula lives in the tap repo `albertofettucini/homebrew-engram` as `Formula/engram.rb`
# (so `brew install albertofettucini/engram/engram` works). This copy is the source of truth; on each
# release, bump `url` + `version` and paste the new `sha256` (printed by the release workflow as
# `engram-cli-macos-universal.tar.gz.sha256`), then copy it into the tap.
#
# It installs the PREBUILT universal CLI binaries from the GitHub Release — no Swift toolchain, no
# compile wait. The desktop app is a separate, unsigned download (see caveats).
class Engram < Formula
  desc "One shared local memory for your AIs — MCP server + Claude Code auto-capture"
  homepage "https://github.com/albertofettucini/Engram"
  url "https://github.com/albertofettucini/Engram/releases/download/v0.1.0/engram-cli-macos-universal.tar.gz"
  version "0.1.0"
  sha256 "REPLACE_AT_RELEASE_WITH_SHA256_OF_engram-cli-macos-universal.tar.gz"
  license "MIT"

  # The CLI tools target macOS 13+. (The GUI app is a separate download and targets macOS 14+.)
  depends_on macos: :ventura

  def install
    bin.install "engram-mcp"
    bin.install "engram-capture"
  end

  def caveats
    <<~EOS
      Connect Engram's memory to Claude Desktop / Claude Code (MCP):
        engram-mcp --connect
        engram-mcp --prepare-embeddings   # optional, one-time on-device model for better recall

      Auto-capture durable facts from your Claude Code chats:
        engram-capture --watch

      The desktop app (memory viewer) is a separate, unsigned download:
        https://github.com/albertofettucini/Engram/releases/latest
    EOS
  end

  test do
    # Drive the MCP server through one JSON-RPC `initialize` and confirm it identifies as "engram".
    # A keystore in the sandbox keeps the test self-contained; EOF after the line exits the read loop.
    ENV["ENGRAM_ROOT"] = testpath/"memories"
    out = pipe_output(
      "#{bin}/engram-mcp",
      %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n),
      0,
    )
    assert_match "engram", out
  end
end
