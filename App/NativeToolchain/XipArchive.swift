import Compression
import Foundation

/// Reads an Apple `.xip` — the container Xcode is distributed in — far enough to
/// pull out the paths a Darwin SDK bundle needs.
///
/// The format is not documented, but it is stable and public in the sense that
/// tools read it (`xar`, `pbzx`, `unxip`):
///
///   **xip** is a xar archive: a 28-byte header (`xar!`, header size, version, the
///   compressed and uncompressed size of the table of contents, a checksum
///   algorithm), a zlib-compressed XML TOC listing the members, then the members'
///   data. An Xcode xip has exactly one member worth reading: `Content`, which
///   holds `Xcode.app`.
///
///   **Content** is a pbzx stream: the bytes `pbzx`, an 8-byte big-endian chunk
///   size, then blocks of (decompressed size, compressed size, bytes) — repeated
///   while a block's decompressed size equals the chunk size. A block is either
///   stored or an **xz** stream, which the two sizes reveal (`pbzx.c` checks for
///   the `\xFD7zXZ` magic, and Apple's `COMPRESSION_LZMA` accepts it).
///
///   **decompressed** it is an `odc` cpio archive (magic `070707`, six-digit octal
///   fields, no alignment padding) of the `Xcode.app` tree, ending at a
///   `TRAILER!!!` entry. `newc` (`070701`, eight-digit hex, four-byte padding) is
///   accepted too: it is what other tools produce, and the cost of accepting both
///   is a branch.
///
/// Two properties shape the API:
///
///  - **It streams.** A full Xcode is ~15 GB and the part that belongs in a build
///    SDK is a small fraction of it, so nothing is ever materialised whole: the
///    walk hands each entry to a closure and only what that closure writes reaches
///    the disk. Peak memory is one decompressed chunk (16 MB for the xips Apple
///    ships) plus the caller's own buffers.
///  - **It is synchronous.** The work is blocking file I/O over a local file, so
///    there is no async surface to get wrong; a caller that does not want to block
///    runs it inside a detached task.
///
/// LZMA and zlib are Apple's own (`Compression`), the same decoders `unxip` uses on
/// Apple platforms, so this needs no vendored library.
enum XipArchive {
    /// A byte range inside the xip, as the archive's TOC records it.
    struct Member: Sendable {
        var offset: Int64
        var length: Int64
    }

    /// One cpio entry. `mode` decides what it is: `0o040000` directory,
    /// `0o120000` symbolic link, `0o100000` regular file.
    struct Entry: Sendable {
        var name: String
        var mode: UInt32
        var size: Int64
        var inode: UInt32
        var device: UInt32
        var linkCount: UInt32

        var isDirectory: Bool { mode & 0o170000 == 0o040000 }
        var isSymlink: Bool { mode & 0o170000 == 0o120000 }
        var isRegular: Bool { mode & 0o170000 == 0o100000 }
    }

    enum Error: LocalizedError {
        case notAXip
        case unsupportedArchive(String)
        case noContentMember
        case unsupportedPayload(String)
        case truncated(String)
        case decompressionFailed(Int64)

        var errorDescription: String? {
            switch self {
            case .notAXip:
                return "That file is not an Apple .xip: it does not start with 'xar!'."
            case .unsupportedArchive(let detail):
                return "Unsupported .xip structure: \(detail)."
            case .noContentMember:
                return "The .xip has no 'Content' member, so there is no Xcode inside it."
            case .unsupportedPayload(let detail):
                return "Unrecognised .xip payload: \(detail)."
            case .truncated(let what):
                return "The .xip ended in the middle of \(what). It is probably incomplete."
            case .decompressionFailed(let offset):
                return "Could not decompress the .xip payload at byte \(offset). The file may be corrupt."
            }
        }
    }

    // MARK: - The xar header and TOC

    /// The `Content` member's byte range, read from the xar table of contents.
    static func content(of url: URL) throws -> Member {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        /// `read(upToCount:)` is allowed to return short, and for a table of contents
        /// or a header that would surface as "the .xip is truncated" on a file that
        /// is perfectly fine.
        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let piece = try handle.read(upToCount: count - data.count),
                      !piece.isEmpty else {
                    throw Error.truncated("the archive header")
                }
                data += piece
            }
            return data
        }

        guard try read(4).elementsEqual(Array("xar!".utf8)) else { throw Error.notAXip }

        let headerSize = Int(try read(2).bigEndian(as: UInt16.self))
        let version = try read(2).bigEndian(as: UInt16.self)
        guard version == 1 else { throw Error.unsupportedArchive("xar version \(version)") }
        let tocCompressedSize = Int(try read(8).bigEndian(as: UInt64.self))
        let tocUncompressedSize = Int(try read(8).bigEndian(as: UInt64.self))
        _ = try read(4)  // checksum algorithm

        // The header is padded to `headerSize`; skip whatever is left of it.
        let consumed = 28
        if headerSize > consumed {
            _ = try read(headerSize - consumed)
        }

        let compressedTOC = try read(tocCompressedSize)
        let toc = try inflate(compressedTOC, to: tocUncompressedSize, what: "the table of contents")

        // A member's `<offset>` is relative to the *heap*, which starts immediately
        // after the compressed TOC — not to the start of the file. Reading it as an
        // absolute offset lands somewhere inside the header and fails on the `pbzx`
        // magic, which is at least a loud way to be wrong.
        let member = try contentMember(inTOC: toc)
        return Member(offset: Int64(headerSize + tocCompressedSize) + member.offset,
                      length: member.length)
    }

    /// The `Content` member of a xar TOC.
    ///
    /// Parsed with `XMLParser` rather than a string scan: the TOC is the one part of
    /// the format whose shape is not fixed (a xip can carry signatures and
    /// metadata), and fishing offsets out of XML by hand is how a format reader
    /// starts to fail on the next release.
    private static func contentMember(inTOC toc: Data) throws -> Member {
        let parser = TOCParser()
        let xml = XMLParser(data: toc)
        xml.delegate = parser
        guard xml.parse() else {
            throw Error.unsupportedArchive(xml.parserError?.localizedDescription ?? "unreadable TOC")
        }
        guard let content = parser.members["Content"] else { throw Error.noContentMember }
        return content
    }

    /// Collects `<file><name>…</name><data><offset>…</offset><length>…</length>`.
    ///
    /// The offset and length are only read *inside* `<data>`: a member's entry can
    /// carry a `<archived-checksum>` with an offset of its own, and taking the last
    /// offset seen would point the payload at the checksum instead of the data.
    private final class TOCParser: NSObject, XMLParserDelegate {
        private(set) var members: [String: Member] = [:]
        private var name: String?
        private var offset: Int64?
        private var length: Int64?
        private var inData = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            switch element {
            case "data": inData = true
            case "name": name = nil
            case "offset" where inData: offset = nil
            case "length" where inData: length = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "name": name = value
            case "offset" where inData: offset = Int64(value)
            case "length" where inData: length = Int64(value)
            case "data": inData = false
            case "file":
                // A `<file>` closes each member, and its `<data>` comes before it, so
                // by now the name/offset/length that belong to it are the last ones
                // seen.
                if let name, let offset, let length {
                    members[name] = Member(offset: offset, length: length)
                }
                name = nil; offset = nil; length = nil; inData = false
            default:
                break
            }
            text = ""
        }
    }

    // MARK: - The pbzx stream

    /// Walk every cpio entry in `Content`.
    ///
    /// `body` is called once per entry with the entry's header and a payload reader
    /// for its data — and it must either read that data or leave it: the walker
    /// consumes whatever is left when `body` returns, because cpio is sequential and
    /// a skipped entry cannot be seeked past. `progress` is handed the fraction of
    /// the *compressed* member consumed, which is monotonic and good enough for a
    /// progress bar.
    ///
    /// Entries are visited in archive order, which is also the order they have to be
    /// written in: a directory always precedes the files inside it.
    static func forEachEntry(
        in url: URL,
        content: Member,
        progress: (@Sendable (Double) -> Void)? = nil,
        _ body: (Entry, Payload) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(content.offset))
        let end = content.offset + content.length

        let stream = try BlockStream(handle: handle, end: end, contentLength: content.length,
                                     progress: progress)
        try readCPIO(from: stream, body)
    }

    /// Decompressed bytes of the payload, one pbzx block at a time.
    ///
    /// A cursor over a sequence of decompressed blocks rather than one buffer: the
    /// payload is ~15 GB decompressed, and a cpio entry — let alone a whole block —
    /// does not respect block boundaries, so reads have to be able to span them.
    fileprivate final class BlockStream {
        private let handle: FileHandle
        private let end: Int64
        private let contentLength: Int64
        private let progress: (@Sendable (Double) -> Void)?
        private var buffer: [UInt8] = []
        private var position = 0
        private var chunkSize: Int64 = 0
        private var finished = false
        private var consumed: Int64 = 0

        init(handle: FileHandle, end: Int64, contentLength: Int64,
             progress: (@Sendable (Double) -> Void)?) throws {
            self.handle = handle
            self.end = end
            self.contentLength = contentLength
            self.progress = progress

            guard try readExact(4).elementsEqual(Array("pbzx".utf8)) else {
                throw Error.unsupportedPayload("the payload does not start with 'pbzx'")
            }
            chunkSize = Int64(try readExact(8).bigEndian(as: UInt64.self))
            guard chunkSize > 0, chunkSize <= 1 << 30 else {
                throw Error.unsupportedPayload("implausible chunk size \(chunkSize)")
            }
        }

        /// The next decompressed block, or `nil` at the end of the payload.
        private func nextBlock() throws -> [UInt8]? {
            if finished { return nil }
            let offset = Int64(handle.offsetInFile)
            if offset >= end { return nil }
            let header = try readUpTo(16)
            guard header.count == 16 else { return nil }
            let decompressedSize = Int64(header[0..<8].bigEndian(as: UInt64.self))
            let compressedSize = Int64(header[8..<16].bigEndian(as: UInt64.self))
            guard decompressedSize > 0, compressedSize > 0 else { return nil }

            // Never read past the member: the archive's own signature and metadata
            // follow it, and swallowing those as payload would be reported as a
            // corrupt xip rather than as the end of the stream.
            let available = end - offset
            let block = try readExact(Int(min(compressedSize, available)))
            // The block is stored when it did not shrink; otherwise it is xz.
            if decompressedSize < chunkSize {
                finished = true
            }
            if Int64(block.count) == decompressedSize {
                return [UInt8](block)
            }
            return try XipArchive.inflateLZMA(block, to: Int(decompressedSize))
        }

        private func loadNext() throws -> Bool {
            guard let block = try nextBlock(), !block.isEmpty else { return false }
            buffer = block
            position = 0
            consumed = Int64(handle.offsetInFile)
            if let progress, contentLength > 0 {
                progress(min(1, Double(consumed) / Double(contentLength)))
            }
            return true
        }

        /// Read up to `count` bytes, across block boundaries. Empty at the end.
        func read(upTo count: Int) throws -> [UInt8] {
            var result: [UInt8] = []
            result.reserveCapacity(count)
            while result.count < count {
                if position >= buffer.count {
                    buffer = []
                    position = 0
                    guard try loadNext() else { break }
                }
                let take = min(count - result.count, buffer.count - position)
                result.append(contentsOf: buffer[position..<(position + take)])
                position += take
            }
            return result
        }

        /// Discard `count` bytes. Same failure mode as `read`, minus the copying.
        func skip(_ count: Int64) throws {
            var remaining = count
            while remaining > 0 {
                if position >= buffer.count {
                    buffer = []
                    position = 0
                    guard try loadNext() else {
                        throw Error.truncated("a cpio entry")
                    }
                }
                let take = min(Int64(buffer.count - position), remaining)
                position += Int(take)
                remaining -= take
            }
        }

        private func readExact(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let piece = try handle.read(upToCount: count - data.count),
                      !piece.isEmpty else {
                    throw Error.truncated("the payload")
                }
                data += piece
            }
            consumed = Int64(handle.offsetInFile)
            return data
        }

        private func readUpTo(_ count: Int) throws -> Data {
            let data = try handle.read(upToCount: count) ?? Data()
            consumed = Int64(handle.offsetInFile)
            return data
        }
    }

    /// A cursor over one entry's data, valid only for the duration of the callback.
    final class Payload {
        private let stream: BlockStream
        private var remaining: Int64

        /// `fileprivate` because it takes a `BlockStream`, which is: only the walk
        /// in this file constructs payloads. `private` would be too narrow — Swift's
        /// `private` does not reach the *enclosing* type, so the walk could not call it.
        fileprivate init(stream: BlockStream, size: Int64) {
            self.stream = stream
            self.remaining = size
        }

        var bytesRemaining: Int64 { remaining }

        /// Up to `count` bytes. Shorter than requested only at the end of the entry.
        func read(upTo count: Int) throws -> [UInt8] {
            guard remaining > 0 else { return [] }
            let chunk = try stream.read(upTo: Int(min(Int64(count), remaining)))
            remaining -= Int64(chunk.count)
            return chunk
        }

        /// Everything left of this entry.
        func readAll() throws -> [UInt8] {
            var result: [UInt8] = []
            while remaining > 0 {
                result.append(contentsOf: try read(upTo: 1 << 20))
            }
            return result
        }

        /// Write the rest of this entry to `url` in `bufferSize` pieces.
        func write(to url: URL, bufferSize: Int = 1 << 20) throws {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try read(upTo: min(bufferSize, Int(remaining)))
                guard !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
        }

        /// Skip to the end of this entry.
        func discard() throws {
            guard remaining > 0 else { return }
            try stream.skip(remaining)
            remaining = 0
        }
    }

    // MARK: - cpio

    /// The numeric part of a cpio entry header.
    ///
    /// Two dialects, and they differ in every field: `odc` (`070707`, which Apple's
    /// xips use) is six-digit octal and has no alignment padding, `newc` (`070701`)
    /// is eight-digit hex and pads the name to four bytes. Only the fields a Darwin
    /// SDK needs are kept — ownership, times and device numbers are dropped rather
    /// than carried around unread.
    private struct RawHeader {
        var mode: UInt32
        var inode: UInt32
        var device: UInt32
        var linkCount: UInt32
        var size: Int64
        var nameLength: Int
        var padded: Bool
    }

    private static func readCPIO(from stream: BlockStream,
                                 _ body: (Entry, Payload) throws -> Void) throws {
        while true {
            try Task.checkCancellation()
            let magic = try stream.read(upTo: 6)
            guard magic.count == 6 else { throw Error.truncated("a cpio entry") }

            let header: RawHeader
            switch String(decoding: magic, as: UTF8.self) {
            case "070707": header = try odcHeader(from: stream)
            case "070701", "070702": header = try newcHeader(from: stream)
            case let other: throw Error.unsupportedPayload("cpio magic '\(other)'")
            }

            let raw = try stream.read(upTo: header.nameLength)
            guard raw.count == header.nameLength, raw.last == 0 else {
                throw Error.unsupportedPayload("unnamed cpio entry")
            }
            let name = String(decoding: raw.dropLast(), as: UTF8.self)
            if header.padded {
                // `newc` aligns the whole header-plus-name to four bytes; the header
                // is 110 bytes, so only the name can push it out of alignment.
                let padding = (4 - ((110 + header.nameLength) % 4)) % 4
                if padding > 0 { try stream.skip(Int64(padding)) }
            }

            // The end marker: there is nothing after it, and its size is zero.
            if name == "TRAILER!!!" { return }

            let payload = Payload(stream: stream, size: header.size)
            let entry = Entry(name: name, mode: header.mode, size: header.size,
                              inode: header.inode, device: header.device,
                              linkCount: header.linkCount)
            try body(entry, payload)
            // Whatever the caller did not read still has to come off the stream:
            // cpio is sequential, so an entry cannot be seeked past.
            try payload.discard()
        }
    }

    /// `odc`: magic consumed, then six-digit octal fields.
    private static func odcHeader(from stream: BlockStream) throws -> RawHeader {
        func octal(_ digits: Int) throws -> UInt32 {
            let bytes = try stream.read(upTo: digits)
            guard bytes.count == digits,
                  let value = UInt32(String(decoding: bytes, as: UTF8.self), radix: 8) else {
                throw Error.unsupportedPayload("unreadable cpio field")
            }
            return value
        }
        // Sizes get their own parse: `odc` gives them eleven octal digits, which is
        // 33 bits, and reading that into a `UInt32` would fail on exactly the large
        // files a compiler's SDK is most likely to contain.
        func sizeField(_ digits: Int) throws -> Int64 {
            let bytes = try stream.read(upTo: digits)
            guard bytes.count == digits,
                  let value = Int64(String(decoding: bytes, as: UTF8.self), radix: 8) else {
                throw Error.unsupportedPayload("unreadable cpio file size")
            }
            return value
        }
        let device = try octal(6)
        let inode = try octal(6)
        let mode = try octal(6)
        _ = try octal(6)  // uid
        _ = try octal(6)  // gid
        let linkCount = try octal(6)
        _ = try octal(6)  // rdev
        _ = try stream.read(upTo: 11)  // mtime
        let nameLength = try octal(6)
        let size = try sizeField(11)

        return RawHeader(mode: mode, inode: inode, device: device, linkCount: linkCount,
                         size: size, nameLength: Int(nameLength), padded: false)
    }

    /// `newc`: magic consumed, then eight-digit hex fields.
    private static func newcHeader(from stream: BlockStream) throws -> RawHeader {
        func hexField<T: FixedWidthInteger>(_ digits: Int, as type: T.Type) throws -> T {
            let bytes = try stream.read(upTo: digits)
            guard bytes.count == digits,
                  let value = T(String(decoding: bytes, as: UTF8.self), radix: 16) else {
                throw Error.unsupportedPayload("unreadable cpio field")
            }
            return value
        }
        let inode = try hexField(8, as: UInt32.self)
        let mode = try hexField(8, as: UInt32.self)
        _ = try hexField(8, as: UInt32.self)  // uid
        _ = try hexField(8, as: UInt32.self)  // gid
        let linkCount = try hexField(8, as: UInt32.self)
        _ = try hexField(8, as: UInt32.self)  // mtime
        let size = try hexField(8, as: Int64.self)
        let deviceMajor = try hexField(8, as: UInt32.self)
        let deviceMinor = try hexField(8, as: UInt32.self)
        _ = try hexField(8, as: UInt32.self)  // rdev major
        _ = try hexField(8, as: UInt32.self)  // rdev minor
        let nameLength = try hexField(8, as: UInt32.self)
        _ = try hexField(8, as: UInt32.self)  // check

        return RawHeader(mode: mode, inode: inode,
                         device: (deviceMajor << 16) | deviceMinor,
                         linkCount: linkCount, size: size,
                         nameLength: Int(nameLength), padded: true)
    }

    // MARK: - Decompression

    /// zlib inflate into a buffer of the declared size.
    static func inflate(_ data: Data, to size: Int, what: String) throws -> Data {
        guard size > 0 else { throw Error.unsupportedPayload("\(what) declares no size") }
        var output = [UInt8](repeating: 0, count: size)
        let written = decode(data, into: &output, algorithm: COMPRESSION_ZLIB)
        guard written == size else { throw Error.unsupportedArchive("could not inflate \(what)") }
        return Data(output)
    }

    /// An xz stream as pbzx stores it, decoded by Apple's own implementation.
    static func inflateLZMA(_ data: Data, to size: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size)
        let written = decode(data, into: &output, algorithm: COMPRESSION_LZMA)
        guard written == size else { throw Error.decompressionFailed(Int64(size)) }
        return output
    }

    /// `compression_decode_buffer`, with the input handed over as a pointer rather
    /// than relying on the implicit array conversion at the call site.
    private static func decode(_ data: Data, into output: inout [UInt8],
                               algorithm: compression_algorithm) -> Int {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, output.count, base, data.count,
                                             nil, algorithm)
        }
    }
}

private extension Data {
    /// Big-endian integer from the leading bytes of this data.
    ///
    /// Assembled by shifting rather than by reinterpreting a byte buffer: the
    /// pointer form reads as `withUnsafeMutableBytes` gymnastics whose element type
    /// inference depends on the enclosing generic, and gets none of that right by
    /// being clever.
    func bigEndian<T: FixedWidthInteger>(as type: T.Type) -> T {
        let width = MemoryLayout<T>.size
        var value: T = 0
        for (index, byte) in prefix(width).enumerated() {
            value |= T(byte) << (8 * (width - 1 - index))
        }
        return value
    }
}
