// Lean iPhoneOS-only `darwin` Swift SDK builder for XForge.
//
// Replicates xtool's SDKBuilder.swift but restricts the SDK to the iPhoneOS
// platform only, skipping the simulator/macOS SDKs and the unrelated platform
// Swift stdlibs. The result is a `darwin.artifactbundle` that SwiftPM can install
// and use to cross-compile to `arm64-apple-ios`.
//
// Usage: swift darwin-sdk-builder.swift <Xcode.app> <output-dir> [aarch64|x86_64]
//
// This script is compiled by `swift` directly (no SPM deps) so it runs in seconds
// on a CI runner; the heavy work is the (trimmed) file copy from Xcode.

import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: <Xcode.app> <outdir> [aarch64|x86_64]\n".data(using: .utf8)!)
    exit(1)
}
let xcodeApp = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let arch = args.count > 3 ? args[3] : "aarch64"

let fm = FileManager.default
let dev = out.appendingPathComponent("Developer")

func run(_ path: String, _ args: [String], cwd: URL? = nil) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "run", code: Int(p.terminationStatus)) }
}

func mkdir(_ u: URL) throws { try fm.createDirectory(at: u, withIntermediateDirectories: true) }

// ---- toolset (ld64.lld linker + swift frontend extras for Linux host) ----
print("[1/6] toolset")
do {
    try mkdir(out)
    let url = URL(string: "https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.0.1/toolset-\(arch).tar.gz")!
    let tmp = out.appendingPathComponent(".toolset.tar.gz")
    print("  downloading \(url.absoluteString)")
    try Data(contentsOf: url).write(to: tmp)
    // The archive has a top-level `bin/` (ld64.lld, dsymutil, libtool); toolset.json
    // expects them under `toolset/bin`, so extract into a `toolset` subdir.
    try mkdir(out.appendingPathComponent("toolset"))
    try run("/usr/bin/tar", ["xzf", tmp.path], cwd: out.appendingPathComponent("toolset"))
    try? fm.removeItem(at: tmp)
}

// ---- copy iPhoneOS platform from Xcode ----
print("[2/6] iPhoneOS platform")
let platform = xcodeApp
    .appendingPathComponent("Contents/Developer/Platforms/iPhoneOS.platform/Developer")
let iphoneOSDest = dev.appendingPathComponent("Platforms/iPhoneOS.platform/Developer")
let sdkSrcDir = platform.appendingPathComponent("SDKs")
let sdkName = try fm.contentsOfDirectory(atPath: sdkSrcDir.path)
    .first { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }!
print("  SDK: \(sdkName)")
try mkdir(iphoneOSDest)
try run("/bin/cp", ["-R", sdkSrcDir.path, iphoneOSDest.appendingPathComponent("SDKs").path])
try run("/bin/cp", ["-R", platform.appendingPathComponent("usr").path,
                    iphoneOSDest.appendingPathComponent("usr").path])
try run("/bin/cp", ["-R", platform.appendingPathComponent("Library").path,
                    iphoneOSDest.appendingPathComponent("Library").path])

// ---- copy Swift stdlib for iphoneos (trimmed to platform + support dirs) ----
print("[3/6] Swift stdlib (iphoneos)")
let toolchain = xcodeApp.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib")
let swiftDest = dev.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib")
let skipPlatforms: Set<String> = [
    "macosx", "macosx-19", "iphonesimulator", "watchos", "tvos",
    "visionos", "linux", "windows", "windows-gnu"
]
func copySwiftDir(named name: String) throws {
    let src = toolchain.appendingPathComponent(name)
    guard fm.fileExists(atPath: src.path) else { print("  (skip \(name): missing)"); return }
    let dst = swiftDest.appendingPathComponent(name)
    try mkdir(dst)
    let children = try fm.contentsOfDirectory(atPath: src.path)
    for child in children {
        let cs = child.lowercased()
        let srcC = src.appendingPathComponent(child)
        var isDir: ObjCBool = false
        fm.fileExists(atPath: srcC.path, isDirectory: &isDir)
        if isDir.boolValue && skipPlatforms.contains(cs) {
            print("  skip \(name)/\(child)")
            continue
        }
        try run("/bin/cp", ["-R", srcC.path, dst.path])
    }
}
try copySwiftDir(named: "swift")
try copySwiftDir(named: "swift_static")

// ---- test framework symlinks (SDK System/Library/Frameworks -> Developer/Library) ----
print("[4/6] test framework symlinks")
let sdkFrameworks = dev
    .appendingPathComponent("Platforms/iPhoneOS.platform/Developer/SDKs/\(sdkName)/System/Library/Frameworks")
try mkdir(sdkFrameworks)
for (name, lib) in [
    ("Testing.framework", "../../../../../Library/Frameworks/Testing.framework"),
    ("XCTest.framework", "../../../../../Library/Frameworks/XCTest.framework"),
    ("XCUIAutomation.framework", "../../../../../Library/Frameworks/XCUIAutomation.framework"),
    ("XCTestCore.framework", "../../../../../Library/PrivateFrameworks/XCTestCore.framework"),
] {
    try fm.createSymbolicLink(atPath: sdkFrameworks.appendingPathComponent(name).path,
                              withDestinationPath: lib)
}

// ---- manifests ----
print("[5/6] manifests")
let sdkRelPath = "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/\(sdkName)"
let toolchainRel = "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"

let infoJSON = """
{
  "schemaVersion": "1.0",
  "artifacts": {
    "darwin": {
      "type": "swiftSDK",
      "version": "0.0.1",
      "variants": [
        {"path": ".", "supportedTriples": ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"]}
      ]
    }
  }
}
"""
try infoJSON.write(to: out.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)

let toolsetJSON = """
{
  "schemaVersion": "1.0",
  "rootPath": "toolset/bin",
  "linker": {"path": "ld64.lld"},
  "swiftCompiler": {
    "extraCLIOptions": ["-Xfrontend", "-enable-cross-import-overlays", "-use-ld=lld"]
  }
}
"""
try toolsetJSON.write(to: out.appendingPathComponent("toolset.json"), atomically: true, encoding: .utf8)

let swiftSDKJSON = """
{
  "schemaVersion": "4.0",
  "targetTriples": {
    "arm64-apple-ios": {
      "sdkRootPath": "\(sdkRelPath)",
      "includeSearchPaths": ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
      "librarySearchPaths": ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
      "swiftResourcesPath": "\(toolchainRel)/swift",
      "swiftStaticResourcesPath": "\(toolchainRel)/swift_static",
      "toolsetPaths": ["toolset.json"]
    }
  }
}
"""
try swiftSDKJSON.write(to: out.appendingPathComponent("swift-sdk.json"), atomically: true, encoding: .utf8)
try "develop\n".write(to: out.appendingPathComponent("darwin-sdk-version.txt"), atomically: true, encoding: .utf8)

// ---- remove the clang/include dir (replaced at install time on the host) ----
print("[6/6] cleanup")
try? fm.removeItem(at: dev
    .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include"))

print("Done. Bundle at \(out.path)")
