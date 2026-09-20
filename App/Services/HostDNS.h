//
//  HostDNS.h
//  XForge
//
//  The device's DNS servers, for the guest's /etc/resolv.conf.
//
//  See HostDNS.c for why this is not SystemConfiguration.
//
#ifndef XFORGE_HOST_DNS_H
#define XFORGE_HOST_DNS_H

#include <stddef.h>

/// Write up to `cap` bytes of the device's DNS servers into `out`, one IPv4 or
/// IPv6 address per line, and return how many were written. Returns 0 when the
/// system does not publish any (no network, or the SPI is unavailable), in
/// which case the caller should fall back to public resolvers.
int xf_host_dns_servers(char *out, size_t cap);

#endif /* XFORGE_HOST_DNS_H */
