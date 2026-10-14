import Foundation

/// The ONE version constant. The MCP server's serverInfo reports it, and the release workflow checks the
/// tag against it — so bump it here (only here) when cutting a release.
public enum EngramVersion {
    public static let current = "0.1.1"
}
