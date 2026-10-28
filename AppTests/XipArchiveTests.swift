import Compression
import Foundation
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
    ///
    /// Bare `developer` rather than `Self.developer` in the two below: a stored
    /// property's initializer cannot reference `Self` at all — the type is still
    /// being built — and inside a *static* property there is no ambiguity to resolve.
    private static let developer = "Xcode.app/Contents/Developer"
    private static let platform = "\(developer)/Platforms/iPhoneOS.platform"
    private static let toolchain = "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib"

    private static func fakeXcode() -> [Spec] {
        var inode: UInt32 = 0
        func next() -> UInt32 { inode += 1; return inode }

        let directories = [
            "Xcode.app", "Xcode.app/Contents", developer, "\(Self.developer)/Platforms",
            platform, "\(Self.platform)/Developer",
            "\(Self.platform)/Developer/SDKs",
            "\(Self.platform)/Developer/SDKs/iPhoneOS27.0.sdk",
            "\(Self.platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr",
            "\(Self.platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr/include",
            "\(Self.developer)/Toolchains", "\(Self.developer)/Toolchains/XcodeDefault.xctoolchain",
            "\(Self.developer)/Toolchains/XcodeDefault.xctoolchain/usr",
            "\(Self.toolchain)", "\(Self.toolchain)/swift_static", "\(Self.toolchain)/swift_static/iphoneos",
            "\(Self.toolchain)/swift", "\(Self.toolchain)/swift/prebuilt-modules",
            "Xcode.app/Contents/Resources",
            "\(Self.developer)/Platforms/MacOSX.platform",
        ]
        var specs = directories.map { Spec(path: $0, mode: directory, inode: next()) }

        // Kept: the platform manifest, a header from the SDK, the Swift static runtime.
        specs.append(Spec(path: "\(Self.platform)/Info.plist", mode: regular,
                          data: Data("<plist/>".utf8), inode: next()))
        specs.append(Spec(path: "\(Self.platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/stdio.h",
                          mode: regular, data: Data("#pragma once\n".utf8), inode: next()))
        let runtimeInode = next()
        specs.append(Spec(path: "\(Self.toolchain)/swift_static/iphoneos/libswiftCore.a",
                          mode: regular, data: Data(repeating: 0xAB, count: 5_000),
                          inode: runtimeInode, links: 2))

        // Dropped: Xcode's own build output, another platform, anything under
        // Contents that is not the Developer directory.
        specs.append(Spec(path: "\(Self.toolchain)/swift/prebuilt-modules/Foundation.swiftmodule",
                          mode: regular, data: Data(repeating: 0xFF, count: 64), inode: next()))
        specs.append(Spec(path: "\(Self.developer)/Platforms/MacOSX.platform/Info.plist",
                          mode: regular, data: Data("<plist/>".utf8), inode: next()))
        specs.append(Spec(path: "Xcode.app/Contents/Resources/Dropped.bin",
                          mode: regular, data: Data(repeating: 0x11, count: 32), inode: next()))
        specs.append(Spec(path: "Xcode.app/Contents/version.plist", mode: regular,
                          data: Data("<plist/>".utf8), inode: next()))

        // The second link to the runtime: same inode, and both are inside the filter,
        // so the bundle should carry one file and one hard link, not two copies.
        specs.append(Spec(path: "\(Self.toolchain)/swift/libswiftCore.a", mode: regular,
                          data: Data(), inode: runtimeInode, links: 2))

        // `iPhoneOS.sdk` is a symlink to the versioned directory in recent Xcodes.
        specs.append(Spec(path: "\(Self.platform)/Developer/SDKs/iPhoneOS.sdk", mode: symlink,
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
    ///
    /// The TOC is a **zlib stream** by default, because that is the only thing
    /// libxar writes: `deflateInit(&zs, Z_BEST_COMPRESSION)` produces RFC 1950, not
    /// raw DEFLATE, and a fixture that skips the container is not a fixture of a
    /// real xip. `toc:` exists so the two shapes a reader may also meet — raw
    /// DEFLATE from a repackager, and a TOC that was never compressed — can be
    /// built and refused or accepted deliberately.
    private enum TOCCompression {
        case zlib
        case rawDeflate
        case stored
    }

    private static func xar(content: Data, toc compression: TOCCompression = .zlib) -> Data {
        let toc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xar><toc><creation-time>0</creation-time><file><name>Content</name><type>file</type>\
        <data><offset>0</offset><length>\(content.count)</length><size>\(content.count)</size>\
        </data><archived-checksum style="SHA1"><offset>\(content.count)</offset>\
        <size>20</size></archived-checksum></file></toc></xar>
        """
        let tocData = Data(toc.utf8)
        let deflate = zlibEncode(tocData) ?? tocData
        let packed: Data
        switch compression {
        case .zlib: packed = zlibWrapped(deflate, of: tocData)
        case .rawDeflate:
            // compression_encode_buffer(COMPRESSION_ZLIB) already emits the
            // RFC 1950 wrapper on Apple platforms; strip it to create raw DEFLATE.
            packed = Data(deflate.dropFirst(2).dropLast(4))
        case .stored: packed = tocData
        }
        var out = Data("xar!".utf8)
        out += bigEndian(UInt16(28), 2)
        out += bigEndian(UInt16(1), 2)
        out += bigEndian(UInt64(packed.count), 8)
        out += bigEndian(UInt64(tocData.count), 8)
        out += bigEndian(UInt32(0), 4)
        out += packed
        out += content
        return out
    }

    /// Put raw DEFLATE inside the RFC 1950 container `deflateInit` writes: the
    /// two-byte CMF/FLG header (`0x78 0xDA` — DEFLATE, 32 KB window, level 9, and
    /// `0x78DA % 31 == 0` as zlib requires) and the Adler-32 trailer.
    ///
    /// Apple's encoder produces only the DEFLATE half — `COMPRESSION_ZLIB` is raw
    /// DEFLATE — so the container has to be built here. That asymmetry is the bug:
    /// the old reader asked `COMPRESSION_ZLIB` to decode a container it cannot read.
    private static func zlibWrapped(_ deflate: Data, of original: Data) -> Data {
        var out = Data([0x78, 0xDA])
        out += deflate
        let checksum = adler32(original)
        out += Data([UInt8((checksum >> 24) & 0xFF), UInt8((checksum >> 16) & 0xFF),
                     UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T, _ width: Int) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0.suffix(width)) }
    }

    private static func zlibEncode(_ data: Data) -> Data? {
        var buffer = [UInt8](repeating: 0, count: data.count + 4_096)
        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let written = compression_encode_buffer(&buffer, buffer.count, base, data.count,
                                                    nil, COMPRESSION_ZLIB)
            return written > 0 ? Data(buffer[0..<written]) : nil
        }
    }

    private static func lzmaEncode(_ data: Data) -> Data? {
        var buffer = [UInt8](repeating: 0, count: data.count * 2 + 4_096)
        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let written = compression_encode_buffer(&buffer, buffer.count, base, data.count,
                                                    nil, COMPRESSION_LZMA)
            return written > 0 ? Data(buffer[0..<written]) : nil
        }
    }

    /// Write a synthesized xip into a fresh temporary directory.
    private func makeXip(payload: Data? = nil) throws -> URL {
        let cpio = payload ?? Self.cpio(Self.fakeXcode())
        return try writeXip(Self.xar(content: Self.pbzx(cpio)))
    }

    /// Write xar bytes into a fresh temporary directory.
    private func writeXip(_ archive: Data) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("Xcode_27.xip")
        try archive.write(to: url)
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
        let magic = try XCTUnwrap(try handle.read(upToCount: 4))
        XCTAssertEqual(magic, Data("pbzx".utf8),
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

    /// A .zip handed to the importer says it is a .zip. The toolchain picker accepts
    /// `.zip` as a type, and "not an Apple .xip" is the wrong sentence for a file
    /// whose first bytes say exactly what it is.
    func testRejectsAZipArchiveWithItsOwnMessage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Xcode.zip-\(UUID().uuidString)")
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data += Data(repeating: 0, count: 64)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try XipArchive.content(of: url)) { error in
            guard let xipError = error as? XipArchive.Error,
                  case .isAZipArchive = xipError else {
                return XCTFail("expected isAZipArchive, got \(error)")
            }
        }
    }

    // MARK: - The table of contents

    /// The regression: every real `.xip` has a TOC that is a **zlib stream**, and the
    /// reader used to hand it to `COMPRESSION_ZLIB`, which is raw DEFLATE and reads
    /// the two-byte container header as a DEFLATE block header. The decode wrote
    /// nothing and the whole archive was reported as
    /// "Unsupported .xip structure: could not inflate the table of contents".
    ///
    /// `makeXip()` builds that shape now, so this test states the property directly
    /// as well: the TOC bytes after the 28-byte header are an RFC 1950 stream, the
    /// payload `zlibDeflatePayload` extracts is what decodes, and the `Content` member
    /// is found where the heap says it is.
    func testLocatesContentInAXipWhoseTableOfContentsIsAZlibStream() throws {
        let payload = Self.pbzx(Self.cpio(Self.fakeXcode()))
        let archive = Self.xar(content: payload, toc: .zlib)
        let url = try writeXip(archive)

        // Byte-for-byte, the shape libxar writes.
        let tocLength = archive[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let tocCompressed = 28 + Int(tocLength)
        let toc = archive.subdata(in: 28..<tocCompressed)
        XCTAssertEqual(Array(toc.prefix(2)), [0x78, 0xDA],
                       "a xar TOC is a zlib stream, not raw DEFLATE")
        XCTAssertEqual((Int(toc[0]) << 8 | Int(toc[1])) % 31, 0,
                       "the zlib header must satisfy zlib's own check")
        XCTAssertEqual(Array(toc.prefix(6)).prefix(2), [0x78, 0xDA].prefix(2))

        // The reader's own split of the container: header and Adler-32 dropped.
        let deflate = try XCTUnwrap(XipArchive.zlibDeflatePayload(in: toc))
        XCTAssertEqual(deflate.count, toc.count - 6)

        let content = try XipArchive.content(of: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(content.offset))
        XCTAssertEqual(try handle.read(upToCount: 4), Data("pbzx".utf8))

        // And the TOC really parses: the member is the one the heap points at.
        XCTAssertEqual(content.length, Int64(payload.count))
    }

    /// The two shapes a reader may also meet, kept working:
    ///
    ///  - raw DEFLATE, which is what a fixture built with Apple's encoder holds and
    ///    what some repackagers write; and
    ///  - a TOC that was never compressed, where `toc_length_compressed` equals
    ///    `toc_length_uncompressed` and the XML is stored as it stands.
    func testAcceptsRawDeflateAndStoredTableOfContents() throws {
        for compression in [Self.TOCCompression.rawDeflate, .stored] {
            let url = try writeXip(Self.xar(content: Self.pbzx(Self.cpio(Self.fakeXcode())),
                                            toc: compression))
            let content = try XipArchive.content(of: url)
            var count = 0
            try XipArchive.forEachEntry(in: url, content: content) { _, _ in count += 1 }
            XCTAssertGreaterThan(count, 10, "the \(compression) TOC should still parse")
        }
    }

    /// Bytes that are not a xip at all still fail, and fail as a *structure* problem
    /// rather than silently pointing the payload at nothing.
    func testRejectsATableOfContentsItCannotInflate() throws {
        var archive = Data("xar!".utf8)
        let junk = Data([0x78, 0xDA, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        archive += Self.bigEndian(UInt16(28), 2)
        archive += Self.bigEndian(UInt16(1), 2)
        archive += Self.bigEndian(UInt64(junk.count), 8)
        archive += Self.bigEndian(UInt64(4_096), 8)   // a lie about the size
        archive += Self.bigEndian(UInt32(1), 4)
        archive += junk
        let url = try writeXip(archive)

        XCTAssertThrowsError(try XipArchive.content(of: url)) { error in
            guard let xipError = error as? XipArchive.Error,
                  case .unsupportedArchive(let detail) = xipError else {
                return XCTFail("expected unsupportedArchive, got \(error)")
            }
            XCTAssertTrue(detail.contains("could not inflate the table of contents"), detail)
        }
    }

    /// `zlibDeflatePayload` is a two-byte judgement, so the two ways to be wrong are
    /// worth pinning: a pair of bytes that is not a zlib header is not one, and a
    /// stream with FDICT set has four more bytes of header to skip.
    func testZlibDeflatePayloadRecognisesOnlyZlibStreams() {
        XCTAssertNil(XipArchive.zlibDeflatePayload(in: Data([0x1F, 0x8B, 0x08, 0x00])))
        XCTAssertNil(XipArchive.zlibDeflatePayload(in: Data([0x78, 0xDA])), "no payload")
        XCTAssertNil(XipArchive.zlibDeflatePayload(in: Data()), "empty")

        // 0x7820 has FDICT set and is divisible by 31.
        let dictionary: [UInt8] = [0x78, 0x20]
        var stream = Data(dictionary)
        stream += Data(repeating: 0, count: 4)     // dictionary id
        stream += Data([0x03, 0x00])               // a stored, empty DEFLATE block
        stream += Data(repeating: 0, count: 4)     // Adler-32
        let payload = XipArchive.zlibDeflatePayload(in: stream)
        XCTAssertEqual(payload?.count, 2, "FDICT moves the payload start by four bytes")
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

    /// The compressed path, validated against an implementation other than this one.
    ///
    /// A pbzx block is an **xz** stream — `pbzx.c` checks for the `\xFD7zXZ` magic and
    /// refuses anything else — and Apple's `COMPRESSION_LZMA` is what decodes it.
    /// This fixture is 787 bytes of odc cpio compressed to 256 bytes by **liblzma**
    /// (Python's `lzma` module, xz container), wrapped in a single pbzx block inside a
    /// xar. Walking it exercises the whole compressed path — the framing decision
    /// (compressed size differs from decompressed size), the xz decode and the cpio
    /// parse — against a stream this process did not produce. An encoder round trip
    /// would have proved nothing: two matching bugs look exactly like correctness.
    func testWalksAnXZPayloadProducedByLiblzma() throws {
        let base64 = """
        /Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4AMSAL1dABgN3wegMRkMF/SCaXaknqoWiVsR\
        ntc2yBB5DloIwewVgm0EJoUwmh+RvTVwtHxlYFJ1cZxGEPK8IgJOaAlEu44Mfu1l8oOZ\
        B6IWQLeOhCnnHNhdx7piLXn/q9nM4+Ka84R4dbk6jozpre+YlFurXBoqU2Bn3zhVpRu1\
        XnLHE0TGI/caB2jNykEyKiHElx5ZcXjGvi+cpoApZ4ZX3NbQxDozsrusWS7CR2dkq2yL\
        Lc5s0cid+htDMzoOxwaAAAAAAAAh8cN2Rcr+YAAB2QGTBgAAcoJ8YLHEZ/sCAAAAAARZ\
        Wg==
        """
        let compressed = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(compressed.prefix(6), Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
                       "the fixture has to be an xz stream, which is what pbzx holds")

        // One block, compressed: the uncompressed size is in the block header, and the
        // two sizes differing is what tells the reader to decompress it.
        let uncompressedSize = 787
        var stream = Data("pbzx".utf8)
        stream += Self.bigEndian(UInt64(4_096), 8)
        stream += Self.bigEndian(UInt64(uncompressedSize), 8)
        stream += Self.bigEndian(UInt64(compressed.count), 8)
        stream += compressed

        let url = try writeXip(Self.xar(content: stream))
        let content = try XipArchive.content(of: url)

        var names: [String] = []
        var stdio: [UInt8] = []
        try XipArchive.forEachEntry(in: url, content: content) { entry, payload in
            names.append(entry.name)
            if entry.name.hasSuffix("/usr/include/stdio.h") {
                stdio = try payload.readAll()
            }
        }

        XCTAssertEqual(names, [
            "Fixture.app",
            "Fixture.app/Developer",
            "Fixture.app/Developer/Info.plist",
            "Fixture.app/Developer/SDKs/iPhoneOS99.0.sdk",
            "Fixture.app/Developer/SDKs/iPhoneOS99.0.sdk/usr",
            "Fixture.app/Developer/SDKs/iPhoneOS99.0.sdk/usr/include/stdio.h",
        ])
        XCTAssertEqual(Data(stdio), Data("#pragma once\n".utf8))
    }

    // MARK: - What becomes the bundle

    /// The filter, checked against the list xtool keeps (`SDKBuilder.wanted`), with
    /// XForge's one deliberate narrowing: the device platform only.
    func testWantedPaths() {
        let kept = [
            "\(Self.developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos/Swift.swiftmodule",
            "\(Self.toolchain)/swift_static/iphoneos/libswiftCore.a",
            // The directory itself is kept: it holds the static runtime, and it is what
            // `swiftStaticResourcesPath` names.
            "\(Self.toolchain)/swift_static/iphoneos",
            "\(Self.toolchain)/swift_static",
            "\(Self.toolchain)/clang/include/stdarg.h",
            "\(Self.platform)/Info.plist",
            "\(Self.platform)/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/stdio.h",
            "\(Self.platform)/Developer/usr/lib/libSystem.tbd",
            "\(Self.platform)/Developer/Library/Frameworks/XCTest.framework/XCTest",
        ]
        for path in kept {
            XCTAssertTrue(DarwinSDKBuilder.isWanted(path), "should be kept: \(path)")
        }

        let dropped = [
            "\(Self.toolchain)/swift/prebuilt-modules/Foundation.swiftmodule",
            "\(Self.developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos/prebuilt-modules/Foundation.swiftmodule",
            "\(Self.developer)/Platforms/MacOSX.platform/Info.plist",
            "\(Self.developer)/Applications/Whatever.app/Whatever",
            "Contents/Resources/English.lproj/InfoPlist.strings",
            "Xcode.app/Contents/version.plist",
            "\(Self.developer)",
            "\(Self.developer)/Platforms",
            "\(Self.developer)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
            "\(Self.developer)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-ide-test",
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
        // Five: the platform manifest, a header, the static runtime, the archive's hard
        // link to it, and the symlink. Directories are not counted.
        XCTAssertGreaterThanOrEqual(result.files, 5)
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
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt"),
                                  encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "27.0")
        XCTAssertTrue(result.hasSwiftStaticRuntime, "the fake Xcode carries the static runtime")

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
            guard let builderError = error as? DarwinSDKBuilder.Error,
                  case .noiPhoneOSSDK = builderError else {
                return XCTFail("expected noiPhoneOSSDK, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("darwin.artifactbundle").path))
    }

    /// Something that is a valid cpio archive but not an Xcode says so, instead of
    /// reporting the absence of an iOS SDK in a tree that has no Xcode at all.
    func testRejectsAnArchiveThatIsNotAnXcode() throws {
        let specs = [
            Spec(path: "Downloads", mode: Self.directory, inode: 1),
            Spec(path: "Downloads/notes.txt", mode: Self.regular,
                 data: Data("hello\n".utf8), inode: 2),
        ]
        let url = try makeXip(payload: Self.cpio(specs))
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(try DarwinSDKBuilder.build(fromXip: url, into: destination)) { error in
            guard let builderError = error as? DarwinSDKBuilder.Error,
                  case .noXcodeInside = builderError else {
                return XCTFail("expected noXcodeInside, got \(error)")
            }
        }
    }

    /// A newer Xcode that keeps no static Swift runtime still produces an SDK: the
    /// headers and tbd stubs are what C targets need, and refusing the import over a
    /// Swift runtime would take those away too. The result says so instead.
    func testImportsWithoutTheSwiftStaticRuntime() throws {
        let specs = Self.fakeXcode().filter { !$0.path.contains("swift_static") }
        let url = try makeXip(payload: Self.cpio(specs))
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("out", isDirectory: true)

        let result = try DarwinSDKBuilder.build(fromXip: url, into: destination)
        XCTAssertFalse(result.hasSwiftStaticRuntime)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bundle.appendingPathComponent("swift-sdk.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.bundle.appendingPathComponent(
                "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/stdio.h").path))
    }
}
