//
//  HostDNS.c
//  XForge
//
//  The device's DNS servers, for the guest's /etc/resolv.conf.
//
//  Resolution happens *inside* the guest, and the Alpine minirootfs XForge
//  bundles ships no nameservers, so the guest cannot resolve anything until
//  something writes that file — `apk add`, and therefore all of
//  install-toolchain.sh, fails with DNS errors without it.
//
//  Where the servers come from, on iOS:
//
//   - SystemConfiguration's dynamic-store API (SCDynamicStoreCopyValue on
//     State:/Network/Global/DNS) is the obvious answer and is what the first
//     version of this used. It is macOS-only: on iOS those symbols are marked
//     unavailable at compile time.
//   - libresolv's res_ninit() would be next, but it is not usable from an app.
//   - What *is* available is libSystem's dnsinfo SPI:
//     dns_configuration_copy(), which is exactly what ish-arm64's own app uses
//     for this same job. It is resolved with dlsym rather than linked, so the
//     app carries no reference to a private symbol; if it ever disappears,
//     this returns 0 and the caller falls back to public resolvers.
//
//  The struct layouts below must match the SPI's. They are the ones ish-arm64
//  ships (app/AppDelegate.m), including the #pragma pack(4).
//
#include "HostDNS.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>

#pragma pack(push, 4)
typedef struct {
    struct in_addr address;
    struct in_addr mask;
} xf_dns_sortaddr_t;

typedef struct {
    char *domain;
    int32_t n_nameserver;
    struct sockaddr **nameserver;
    uint16_t port;
    int32_t n_search;
    char **search;
    int32_t n_sortaddr;
    xf_dns_sortaddr_t **sortaddr;
    char *options;
    uint32_t timeout;
    uint32_t search_order;
    uint32_t if_index;
    uint32_t flags;
    uint32_t reach_flags;
    uint32_t reserved[5];
} xf_dns_resolver_t;

typedef struct {
    int32_t n_resolver;
    xf_dns_resolver_t **resolver;
    int32_t n_scoped_resolver;
    xf_dns_resolver_t **scoped_resolver;
    uint32_t reserved[5];
} xf_dns_config_t;
#pragma pack(pop)

typedef xf_dns_config_t *(*xf_dns_copy_fn)(void);
typedef void (*xf_dns_free_fn)(xf_dns_config_t *);

// Copies rather than casts: the resolver and nameserver arrays are arrays of
// pointers that the SPI does not promise are aligned for the destination type.
static xf_dns_resolver_t *xf_resolver_at(xf_dns_resolver_t **resolvers, int index) {
    xf_dns_resolver_t *resolver = NULL;
    if (resolvers == NULL || index < 0)
        return NULL;
    memcpy(&resolver, resolvers + index, sizeof(resolver));
    return resolver;
}

static struct sockaddr *xf_nameserver_at(struct sockaddr **nameservers, int index) {
    struct sockaddr *address = NULL;
    if (nameservers == NULL || index < 0)
        return NULL;
    memcpy(&address, nameservers + index, sizeof(address));
    return address;
}

int xf_host_dns_servers(char *out, size_t cap) {
    static xf_dns_copy_fn copy_fn;
    static xf_dns_free_fn free_fn;
    static int looked_up = 0;
    if (!looked_up) {
        looked_up = 1;
        copy_fn = (xf_dns_copy_fn) dlsym(RTLD_DEFAULT, "dns_configuration_copy");
        free_fn = (xf_dns_free_fn) dlsym(RTLD_DEFAULT, "dns_configuration_free");
    }
    if (copy_fn == NULL || free_fn == NULL || out == NULL || cap == 0)
        return 0;

    xf_dns_config_t *config = copy_fn();
    if (config == NULL)
        return 0;

    size_t used = 0;
    int written = 0;
    out[0] = '\0';

    for (int r = 0; r < config->n_resolver; r++) {
        xf_dns_resolver_t *resolver = xf_resolver_at(config->resolver, r);
        if (resolver == NULL || resolver->n_nameserver <= 0)
            continue;
        // mDNS resolvers (.local) list 224.0.0.251, which is not a nameserver
        // to hand to musl.
        if (resolver->options != NULL && strcmp(resolver->options, "mdns") == 0)
            continue;

        for (int i = 0; i < resolver->n_nameserver; i++) {
            struct sockaddr *address = xf_nameserver_at(resolver->nameserver, i);
            if (address == NULL)
                continue;
            char text[INET6_ADDRSTRLEN] = {0};
            void *source = NULL;
            if (address->sa_family == AF_INET)
                source = &((struct sockaddr_in *) address)->sin_addr;
            else if (address->sa_family == AF_INET6)
                source = &((struct sockaddr_in6 *) address)->sin6_addr;
            else
                continue;
            if (inet_ntop(address->sa_family, source, text, sizeof(text)) == NULL)
                continue;
            if (text[0] == '\0')
                continue;

            // Skip duplicates: the SPI lists one resolver per interface.
            if (strstr(out, text) != NULL)
                continue;

            size_t len = strlen(text);
            if (used + len + 2 > cap)
                break;
            memcpy(out + used, text, len);
            used += len;
            out[used++] = '\n';
            out[used] = '\0';
            written++;
            if (written >= 4)
                goto done;
        }
    }

done:
    free_fn(config);
    return written;
}
