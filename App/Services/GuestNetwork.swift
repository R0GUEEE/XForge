import Foundation

/// The guest's `nameserver` configuration.
///
/// The engine hands the guest the host's sockets, but **name resolution happens
/// inside the guest**: musl (and busybox's `wget`, and `apk`) read
/// `/etc/resolv.conf`, and the Alpine minirootfs XForge bundles ships no
/// nameservers at all. iSH-AOK's own app writes that file from the device's DNS
/// on every boot for exactly this reason; without the same step the guest
/// resolves nothing — `apk add`, `git clone` and the Swift toolchain download in
/// `install-toolchain.sh` all fail with `bad address` / `DNS: transient error`.
///
/// Verified on the host harness before this existed: `wget` in a booted guest
/// answered `bad address 'dl-cdn.alpinelinux.org'`, and `apk update` reported
/// "DNS: transient error" for every repository. With the resolver configured the
/// same guest answers `net-ok` and `apk update` reports 27,453 packages.
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

    /// Fallback for when the system publishes nothing. Both are public
    /// resolvers; a device with no network at all will fail either way, but a
    /// device whose DNS simply was not advertised (some VPNs) will work.
    static let fallbackServers = ["1.1.1.1", "8.8.8.8"]

    static func resolvConf(servers: [String]) -> String {
        let list = servers.isEmpty ? fallbackServers : servers
        return list.map { "nameserver \($0)" }.joined(separator: "\n") + "\n"
    }

    /// The file the guest should have, using the device's DNS when it is known.
    static func resolvConfForDevice() -> (text: String, source: String) {
        let serverList = systemDNSServers()
        return serverList.isEmpty
            ? (resolvConf(servers: serverList), "fallback")
            : (resolvConf(servers: serverList), "device")
    }
}
