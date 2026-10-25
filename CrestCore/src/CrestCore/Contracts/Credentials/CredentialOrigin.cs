using System.Net;
using System.Net.Sockets;

namespace CrestCore.Contracts;

/// The canonical HTTP(S) origin a credential belongs to. The platform
/// canonicalizes scheme, host and default port before it reaches the core, so
/// equality is exact member equality. The credential rules refuse an origin
/// that is not `IsValid`.
public sealed record CredentialOrigin(string Scheme, string Host, int Port) {
    #region Variables

    public const int MaximumHostLength = 1_024;

    /// A host with a colon must be a plain IPv6 address: a page's origin never
    /// holds a zone ID, brackets or escapes.
    public bool IsValid => WebScheme.Named(Scheme) is not null && !string.IsNullOrEmpty(Host) && Host.Length <= MaximumHostLength
        && (!Host.Contains(':', StringComparison.Ordinal) || IsIPv6Address(Host)) && Port is >= 1 and <= 65_535;

    public bool IsSecure => WebScheme.Named(Scheme)?.IsSecure == true;

    /// The origin as an address spells it: its scheme and host, an IPv6 host
    /// in brackets, and its port only where it is not the scheme's default.
    public string Spelling {
        get {
            string host = Host.Contains(':', StringComparison.Ordinal) ? $"[{Host}]" : Host;
            return WebScheme.Named(Scheme)?.DefaultPort == Port ? $"{Scheme}://{host}" : $"{Scheme}://{host}:{Port}";
        }
    }

    #endregion

    #region Actions - Capture

    /// Whether a frame at this origin under a top-level page at
    /// `topLevelOrigin` may capture and be offered credentials: both must be
    /// secure.
    internal bool IsSecureUnder(CredentialOrigin topLevelOrigin) {
        ArgumentNullException.ThrowIfNull(topLevelOrigin);
        return Validated().IsSecure && topLevelOrigin.Validated().IsSecure;
    }

    /// This origin, or the refusal of one that is not `IsValid`.
    internal CredentialOrigin Validated() => IsValid ? this : throw new Rejected(new InvalidCredentialOrigin());

    #endregion

    #region Actions - Host

    /// `IPAddress.TryParse` alone also takes brackets and a zone ID.
    private static bool IsIPv6Address(string host) =>
        host.All(character => char.IsAsciiHexDigit(character) || character is ':' or '.')
        && IPAddress.TryParse(host, out var address) && address.AddressFamily == AddressFamily.InterNetworkV6;

    #endregion
}
