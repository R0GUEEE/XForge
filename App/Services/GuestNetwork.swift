import Foundation

/// The guest's `nameserver` configuration.
///
/// The engine hands the guest the host's sockets, but **name resolution happens
/// inside the guest**: musl (and busybox's `wget`, and `apk`) read
/// `/etc/resolv.conf`, and the Alpine minirootfs XForge bundles ships no
/// nameservers at all. iSH-AOK's own app writes that file from the device's DNS
/// on every boot for exactly this reason; without the same step the guest
/// resolves nothing — `apk add`, and therefore all of
/// `install-toolchain.sh`, fails with `DNS: transient error`.
///
/// **Order matters, and it is not the obvious one.** A home network hands out
/// its router (`192.168.x.1`), which is a *local* address: iOS refuses
/// connections to those unless the user has granted Local Network access, and
/// the guest's DNS queries are made by this very process, so the refusal lands
/// as an in-guest "DNS: transient error" with a correct-looking resolv.conf.
/// Observed exactly that on a device whose resolver was `192.168.4.1`: the file
/// was right, `apk` still failed.
///
/// So the public resolvers go first — they are reachable without any
/// permission — and the device's own servers are kept as the fallback for
/// networks where public DNS is blocked (captive portals, some VPNs).
enum GuestNetwork {
    /// The device's DNS servers, in preference order. Empty when the system
    /// will not say (no network, or the dnsinfo SPI is unavailable) — see
    /// HostDNS.c for why this is not SystemConfiguration.
    static func systemDNSServers() -> [String] {
        var buffer = [CChar](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            return xf_host_dns_servers(base, pointer.count)
        }
        guard count > 0 else { return [] }
        return String(cString: buffer)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Reachable without Local Network permission, so they are tried first.
    static let publicServers = ["1.1.1.1", "8.8.8.8"]

    /// musl reads every `nameserver` line and tries them in order, so the list
    /// is short on purpose: a dead entry costs a timeout before the next one.
    static let maxServers = 3

    static func resolvConf(servers: [String]) -> String {
        var ordered: [String] = []
        for server in publicServers + servers where !ordered.contains(server) {
            ordered.append(server)
            if ordered.count == maxServers { break }
        }
        return ordered.map { "nameserver \($0)" }.joined(separator: "\n") + "\n"
    }

    /// The file the guest should have. `source` says which servers were
    /// actually used, for the engine log.
    static func resolvConfForDevice() -> (text: String, source: String) {
        let deviceServers = systemDNSServers()
        let text = resolvConf(servers: deviceServers)
        let source = deviceServers.isEmpty
            ? "public (the device published none)"
            : "public + device (\(deviceServers.joined(separator: ", ")))"
        return (text, source)
    }
}
