//
//  XForge-Bridging-Header.h
//  XForge
//
//  Exposes the C shims to Swift: the embedded Linux engine bridge (ish-arm64)
//  and the host DNS reader (which keeps the guest's /etc/resolv.conf correct).
//
#import "ISHBridge.h"
#import "HostDNS.h"
#import "NativeToolchainBridge.h"
