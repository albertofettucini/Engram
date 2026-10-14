# Engram Homebrew formula — STAGING COPY.
#
# The live formula lives in the tap repo `albertofettucini/homebrew-engram` as `Formula/engram.rb`
# (so `brew install albertofettucini/engram/engram` works). This copy is the source of truth; on each
# release, `packaging/bump-formula.sh` sets `url`, `version` and `sha256` here and in the tap clone
# (see packaging/RELEASE.md).
#
# It installs the PREBUILT universal CLI binaries from the GitHub Release — no Swift toolchain, no
# compile wait. The desktop app is a separate download, ad-hoc signed, not notarized (see caveats).
class Engram < Formula
  desc "Local, on-device memory for your AIs (MCP server)"
  homepage "https://github.com/albertofettucini/Engram"
  url "https://github.com/albertofettucini/Engram/releases/download/v0.1.1/engram-cli-macos-universal.tar.gz"
  version "0.1.1"
  sha256 "18b55511395a7c4f72ddd6b8e8843155f55e104df0db61c37661a1542cfbf9f3"
  license "MIT"

  # The CLI tools target macOS 13+. (The GUI app is a separate download and targets macOS 14+.)
  depends_on macos: :ventura

  def install
    bin.install "engram-mcp"
    bin.install "engram-capture"
  end

  def caveats
    <<~EOS
      Connect Engram to Claude Desktop and Claude Code:
        engram-mcp --connect
      Check the setup any time:
        engram-mcp --doctor
      Optional, one-time on-device model for better recall:
        engram-mcp --prepare-embeddings

      The desktop app (memory viewer) is a separate download. It isn't notarized, so the
      first launch needs System Settings → Privacy & Security → Open Anyway:
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
