import Compression
import XCTest
@testable import XForge

/// The `.xip` reader and the Darwin SDK builder.
///
/// There is no real Xcode xip to test against — they are 11 GB and need an Apple ID —
/// so these tests build one, layer by layer, the way the format notes in `XipArchive`
/// describe it: `odc` cpio inside pbzx blocks inside a xar. Two things that would
/// otherwise go untested are covered anyway: the pbzx framing is exercised across
/// block boundaries and with both a stored and a compressed block, and the LZMA
/// decode is checked against a fixture produced by **liblzma** (Python's `lzma`
/// module), so the decoder is validated against a different implementation than its
/// own encoder.
final class XipArchiveTests: XCTestCase {

    // MARK: - Fixture scaffolding

    private struct Spec {
        var path: String
        var mode: UInt32
        var data: Data = Data()
        var inode: UInt32
        var links: UInt32 = 1
    }

    private static let directory: UInt32 = 0o040755
    private static let regular: UInt32 = 0o100644
    private static let symlink: UInt32 = 0o120777

    /// The paths of the fake Xcode tree, rooted at `Xcode.app` as the archive's are.
    private static let developer = "Xcode.app/Contents/Developer"
    private static let platform = "\(developer)/Platforms/iPhoneOS.platform"
    private static let toolchain = "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib"

    private static func fakeXcode() -> [Spec] {
        var inode: UInt32 = 0
        func next() -> UInt32 { inode += 1; return inode }

        let directories = [
            "Xcode.app", "Xcode.app/Contents", developer, "\(developer)/Platforms",
            platform, "\(platform)/Developer",
            "\(platform)/Developer/SDKs",
            "\(platform)/Developer/SDKs/iPhoneOS27.0.sdk",
            "\(platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr",
            "\(platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr/include",
            "\(developer)/Toolchains", "\(developer)/Toolchains/XcodeDefault.xctoolchain",
            "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr",
            "\(toolchain)", "\(toolchain)/swift_static", "\(toolchain)/swift_static/iphoneos",
            "\(toolchain)/swift", "\(toolchain)/swift/prebuilt-modules",
            "Xcode.app/Contents/Resources",
            "\(developer)/Platforms/MacOSX.platform",
        ]
        var specs = directories.map { Spec(path: $0, mode: directory, inode: next()) }

        // Kept: the platform manifest, a header from the SDK, the Swift static runtime.
        specs.append(Spec(path: "\(platform)/Info.plist", mode: regular,
                          data: Data("<plist/>".utf8), inode: next()))
        specs.append(Spec(path: "\(platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/stdio.h",
                          mode: regular, data: Data("#pragma once\n".utf8), inode: next()))
        let runtimeInode = next()
        specs.append(Spec(path: "\(toolchain)/swift_static/iphoneos/libswiftCore.a",
                          mode: regular, data: Data(repeating: 0xAB, count: 5_000),
                          inode: runtimeInode, links: 2))

        // Dropped: Xcode's own build output, another platform, anything under
        // Contents that is not the Developer directory.
        specs.append(Spec(path: "\(toolchain)/swift/prebuilt-modules/Foundation.swiftmodule",
                          mode: regular, data: Data(repeating: 0xFF, count: 64), inode: next()))
        specs.append(Spec(path: "\(developer)/Platforms/MacOSX.platform/Info.plist",
                          mode: regular, data: Data("<plist/>".utf8), inode: next()))
        specs.append(Spec(path: "Xcode.app/Contents/Resources/Dropped.bin",
                          mode: regular, data: Data(repeating: 0x11, count: 32), inode: next()))
        specs.append(Spec(path: "Xcode.app/Contents/version.plist", mode: regular,
                          data: Data("<plist/>".utf8), inode: next()))

        // The second link to the runtime: same inode, and both are inside the filter,
        // so the bundle should carry one file and one hard link, not two copies.
        specs.append(Spec(path: "\(toolchain)/swift/libswiftCore.a", mode: regular,
                          data: Data(), inode: runtimeInode, links: 2))

        // `iPhoneOS.sdk` is a symlink to the versioned directory in recent Xcodes.
        specs.append(Spec(path: "\(platform)/Developer/SDKs/iPhoneOS.sdk", mode: symlink,
                          data: Data("iPhoneOS27.0.sdk".utf8), inode: next()))
        return specs
    }

    private static func cpio(_ specs: [Spec]) -> Data {
        var out = Data()
        for spec in specs { out += odcEntry(spec) }
        out += odcEntry(Spec(path: "TRAILER!!!", mode: 0, inode: 0))
        return out
    }

    /// `odc`: magic, six-digit octal fields, an 11-digit size, then the name and data.
    private static func odcEntry(_ spec: Spec) -> Data {
        func octal(_ value: UInt32, _ width: Int) -> Data {
            Data(String(format: "%0\(width)o", value).utf8)
        }
        var out = Data("070707".utf8)
        out += octal(0, 6)                                             // device
        out += octal(spec.inode, 6)                                    // inode
        out += octal(spec.mode, 6)                                     // mode
        out += octal(0, 6)                                             // uid
        out += octal(0, 6)                                             // gid
        out += octal(spec.links, 6)                                    // link count
        out += octal(0, 6)                                             // rdev
        out += octal(0, 11)                                            // mtime
        out += octal(UInt32(spec.path.utf8.count + 1), 6)              // name length
        out += octal(UInt32(spec.data.count), 11)                      // file size
        out += Data(spec.path.utf8)
        out += Data([0])
        out += spec.data
        return out
    }

    /// pbzx-wrap a payload. The first block is LZMA-compressed when the platform can
    /// encode it (Apple's LZMA encoder is decode-mostly), the rest are stored — the
    /// same mix a real xip has.
    private static func pbzx(_ payload: Data, chunkSize: Int = 2_048) -> Data {
        var out = Data("pbzx".utf8)
        out += bigEndian(UInt64(chunkSize), 8)
        var index = payload.startIndex
        var block = 0
        while index < payload.endIndex {
            let end = payload.index(index, offsetBy: chunkSize, limitedBy: payload.endIndex)
                ?? payload.endIndex
            let uncompressed = Data(payload[index..<end])
            index = end
            var stored = uncompressed
            if block == 0, let compressed = lzmaEncode(uncompressed) { stored = compressed }
            out += bigEndian(UInt64(uncompressed.count), 8)
            out += bigEndian(UInt64(stored.count), 8)
            out += stored
            block += 1
        }
        return out
    }

    /// A xar with a single `Content` member, whose `<offset>` is heap-relative.
    ///
    /// The `<archived-checksum>` is not decoration: it carries an `<offset>` of its
    /// own, and a reader that takes the last offset it sees points the payload at the
    /// checksum. A real xip's TOC has one, so this fixture does too.
    private static func xar(content: Data) -> Data {
        let toc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xar><toc><creation-time>0</creation-time><file><name>Content</name><type>file</type>\
        <data><offset>0</offset><length>\(content.count)</length><size>\(content.count)</size>\
        </data><archived-checksum style="SHA1"><offset>\(content.count)</offset>\
        <size>20</size></archived-checksum></file></toc></xar>
        """
        let tocData = Data(toc.utf8)
        let compressed = zlibEncode(tocData) ?? tocData
        var out = Data("xar!".utf8)
        out += bigEndian(UInt16(28), 2)
        out += bigEndian(UInt16(1), 2)
        out += bigEndian(UInt64(compressed.count), 8)
        out += bigEndian(UInt64(tocData.count), 8)
        out += bigEndian(UInt32(0), 4)
        out += compressed
        out += content
        return out
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T, _ width: Int) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0.suffix(width)) }
    }

    private static func zlibEncode(_ data: Data) -> Data? {
        var buffer = [UInt8](repeating: 0, count: data.count + 4_096)
        let written = compression_encode_buffer(&buffer, buffer.count, [UInt8](data), data.count,
                                                nil, COMPRESSION_ZLIB)
        return written > 0 ? Data(buffer[0..<written]) : nil
    }

    private static func lzmaEncode(_ data: Data) -> Data? {
        var buffer = [UInt8](repeating: 0, count: data.count * 2 + 4_096)
        let written = compression_encode_buffer(&buffer, buffer.count, [UInt8](data), data.count,
                                                nil, COMPRESSION_LZMA)
        return written > 0 ? Data(buffer[0..<written]) : nil
    }

    /// Write a synthesized xip into a fresh temporary directory.
    private func makeXip(payload: Data? = nil) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let cpio = payload ?? Self.cpio(Self.fakeXcode())
        let url = directory.appendingPathComponent("Xcode_27.xip")
        try Self.xar(content: Self.pbzx(cpio)).write(to: url)
        return url
    }

    // MARK: - The xar layer

    /// The `Content` member's byte range. The TOC records a *heap-relative* offset, so
    /// a reader that treats it as absolute lands inside the header and finds no pbzx
    /// magic — which is what this pins down.
    func testContentMemberIsLocatedAfterTheTableOfContents() throws {
        let url = try makeXip()
        let content = try XipArchive.content(of: url)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(content.offset))
        let magic = try handle.read(upToCount: 4)
        XCTAssertEqual(magic.map { [UInt8]($0) }, Array("pbzx".utf8),
                       "the Content member should start at the pbzx stream")
        XCTAssertGreaterThan(content.length, 0)
    }

    func testRejectsAFileThatIsNotAXip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-xip-\(UUID().uuidString).xip")
        try Data("this is just a file".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try XipArchive.content(of: url)) { error in
            guard let xipError = error as? XipArchive.Error, case .notAXip = xipError else {
                return XCTFail("expected notAXip, got \(error)")
            }
        }
    }

    // MARK: - The pbzx and cpio layers

    /// Every entry, in order, with the shapes intact — and across block boundaries:
    /// the fixture's chunk size is 2 KB and the fake tree is larger than that.
    func testWalkYieldsEveryEntry() throws {
        let url = try makeXip()
        let content = try XipArchive.content(of: url)

        var entries: [XipArchive.Entry] = []
        var payloads: [String: Int] = [:]
        try XipArchive.forEachEntry(in: url, content: content) { entry, payload in
            entries.append(entry)
            payloads[entry.name] = try payload.readAll().count
        }

        let names = entries.map(\.name)
        XCTAssertTrue(names.contains("\(Self.platform)/Info.plist"))
        XCTAssertFalse(names.contains("TRAILER!!!"), "the trailer ends the walk")
        XCTAssertEqual(entries.filter(\.isDirectory).count,
                       Self.fakeXcode().filter { $0.mode == Self.directory }.count)

        // A file's data has to survive whole even when it straddles blocks.
        XCTAssertEqual(payloads["\(Self.toolchain)/swift_static/iphoneos/libswiftCore.a"], 5_000)
        XCTAssertEqual(payloads["\(Self.platform)/Info.plist"], Data("<plist/>".utf8).count)

        // A symlink's "data" is its target, which is how the bundle recreates it.
        let link = entries.first { $0.name.hasSuffix("/SDKs/iPhoneOS.sdk") }
        XCTAssertEqual(link?.isSymlink, true)
        XCTAssertEqual(payloads["\(Self.platform)/Developer/SDKs/iPhoneOS.sdk"], 16)
    }

    /// The one part that has to agree with another implementation of the format.
    ///
    /// The blob is 420 bytes of text compressed to 85 bytes of **raw LZMA2** by
    /// liblzma, which is what a pbzx block holds. Apple's decoder has to reproduce it
    /// byte for byte; an encoder round-trip through this process would have proved
    /// nothing, since two matching bugs look exactly like correctness.
    func testDecodesRawLZMA2ProducedByLiblzma() throws {
        let base64 = """
        4AGjAE1dACwaSgQTYMiZxu0IMKQ6+2aC3gaIG0RBZoQd0tB/LAu8gQdovsXeV7hHLo7E0RzTAygy\
        1lQcyW1wiJyvt23W96lpWfeimqcQPsLwdAAAAA==
        """
        let compressed = try XCTUnwrap(Data(base64Encoded: base64))
        let expected = Data(String(repeating: "XipArchive: a pbzx block is raw LZMA2, "
                                   + "decoded with COMPRESSION_LZMA. ", count: 6).utf8)
        XCTAssertEqual(expected.count, 420, "the fixture and this payload must stay in step")

        let decoded = try XipArchive.inflateLZMA(compressed, to: expected.count)
        XCTAssertEqual(Data(decoded), expected)
    }

    // MARK: - What becomes the bundle

    /// The filter, checked against the list xtool keeps (`SDKBuilder.wanted`), with
    /// XForge's one deliberate narrowing: the device platform only.
    func testWantedPaths() {
        let kept = [
            "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos/Swift.swiftmodule",
            "\(toolchain)/swift_static/iphoneos/libswiftCore.a",
            "\(toolchain)/clang/include/stdarg.h",
            "\(platform)/Info.plist",
            "\(platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/stdio.h",
            "\(platform)/Developer/usr/lib/libSystem.tbd",
            "\(platform)/Developer/Library/Frameworks/XCTest.framework/XCTest",
        ]
        for path in kept {
            XCTAssertTrue(DarwinSDKBuilder.isWanted(path), "should be kept: \(path)")
        }

        let dropped = [
            "\(toolchain)/swift/prebuilt-modules/Foundation.swiftmodule",
            "\(developer)/Platforms/MacOSX.platform/Info.plist",
            "\(developer)/Applications/Whatever.app/Whatever",
            "Contents/Resources/English.lproj/InfoPlist.strings",
            "Xcode.app/Contents/version.plist",
            "\(toolchain)/swift_static/iphoneos",
            "\(developer)",
        ]
        for path in dropped {
            XCTAssertFalse(DarwinSDKBuilder.isWanted(path), "should be dropped: \(path)")
        }
    }

    // MARK: - End to end

    /// An `.xip` in, a `darwin.artifactbundle` out — one the app's own reader accepts.
    func testBuildsAnInstallableBundleFromAXip() throws {
        let url = try makeXip()
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("out", isDirectory: true)

        let result = try DarwinSDKBuilder.build(fromXip: url, into: destination)
        XCTAssertGreaterThan(result.files, 5)
        XCTAssertGreaterThan(result.skipped, 0, "the unwanted paths should be counted as skipped")
        XCTAssertEqual(result.sdkRoot,
                       "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk")

        let bundle = result.bundle
        let fileManager = FileManager.default
        func exists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: bundle.appendingPathComponent(relative).path)
        }

        XCTAssertTrue(exists("Developer/Platforms/iPhoneOS.platform/Info.plist"))
        XCTAssertTrue(exists("Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/stdio.h"))
        XCTAssertTrue(exists("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static/iphoneos/libswiftCore.a"))

        // The tree is re-rooted at Developer/, not copied as Xcode.app.
        XCTAssertFalse(exists("Xcode.app"))

        XCTAssertFalse(exists("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/prebuilt-modules/Foundation.swiftmodule"))
        XCTAssertFalse(exists("Developer/Platforms/MacOSX.platform/Info.plist"))
        XCTAssertFalse(exists("Contents/Resources/Dropped.bin"))

        // The symlink is a symlink, pointing at the versioned SDK directory.
        let sdkLink = bundle.appendingPathComponent(
            "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: sdkLink.path),
                       "iPhoneOS27.0.sdk")

        // The two links to one inode stay one file plus a link.
        func inode(_ relative: String) throws -> NSNumber? {
            let attributes = try fileManager.attributesOfItem(
                atPath: bundle.appendingPathComponent(relative).path)
            return attributes[.systemFileNumber] as? NSNumber
        }
        let runtime = try inode("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static/iphoneos/libswiftCore.a")
        let other = try inode("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/libswiftCore.a")
        XCTAssertEqual(runtime, other, "the archive's hard link should stay a hard link")

        // The metadata, as `NativeSDK` reads it.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: bundle.appendingPathComponent("swift-sdk.json")))
                as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? String, "4.0")
        let triples = try XCTUnwrap(json["targetTriples"] as? [String: Any])
        let triple = try XCTUnwrap(triples["arm64-apple-ios"] as? [String: Any])
        XCTAssertEqual(triple["sdkRootPath"] as? String, result.sdkRoot)
        XCTAssertEqual(triple["swiftStaticResourcesPath"] as? String,
                       "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static")
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt"))
            .trimmingCharacters(in: .whitespacesAndNewlines), "27.0")

        // And the app's own reader resolves it — the assertion that matters, because a
        // bundle nothing can read is not an SDK.
        let layout = try NativeSDK.layout(at: bundle)
        XCTAssertEqual(layout.sdkRoot.lastPathComponent, "iPhoneOS27.0.sdk")
        XCTAssertEqual(layout.swiftStaticResources?.lastPathComponent, "swift_static")
        XCTAssertTrue(layout.swiftRuntimeLibraryPaths.contains {
            $0.path.hasSuffix("/swift_static/iphoneos")
        })
    }

    /// A xip without an iPhoneOS SDK is refused with a message that says so, rather
    /// than installing a bundle that fails later.
    func testRejectsAXipWithNoIPhoneOSSDK() throws {
        let specs = [
            Spec(path: "Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Info.plist",
                 mode: Self.regular, data: Data("<plist/>".utf8), inode: 1),
        ]
        let url = try makeXip(payload: Self.cpio(specs))
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(try DarwinSDKBuilder.build(fromXip: url, into: destination)) { error in
            guard case DarwinSDKBuilder.Error.noiPhoneOSSDK = error else {
                return XCTFail("expected noiPhoneOSSDK, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("darwin.artifactbundle").path))
    }
}
