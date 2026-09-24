import Foundation

/// A read-only view of an existing Xcode project (`Foo.xcodeproj`).
///
/// This is the foundation of the "Xcode alternative" path: an Xcode project file
/// is the only description of what an existing app is made of, and it is a text
/// property list, so it can be read on-device — no Mac, no `xcodebuild`.
///
/// It answers the questions a build driver has to ask first: which targets are
/// there, what they produce, which sources they compile, and what their build
/// settings are after the project's own inheritance rules — project settings,
/// project xcconfig, target xcconfig, target settings, in Xcode's order.
///
/// **Why the parser is written here.** `tuist/XcodeProj` would do this, but it
/// cannot be used: the app's `xtool` dependency resolves `XcodeGen`, which pins
/// `XcodeProj` with `exact:` (9.14.0 today), so a newer XcodeProj is
/// unsatisfiable — asking for one made SwiftPM's resolver spin for 40+ minutes in
/// CI — and the pinned version declares no iOS support at all. `project.pbxproj`
/// is an OpenStep property list, and the subset it uses is small, so XForge owns
/// a parser instead of fighting the graph. See Docs/XCODE-ALTERNATIVE.md.
///
/// Deliberately *not* here yet:
///  - anything that compiles (see `NativeToolchain`/`EmbeddedLinuxExecutor`);
///  - `$(...)` evaluation, `[config=…]` conditions and Xcode's huge default
///    settings table: values are reported as written;
///  - schemes, asset catalogs and storyboards. `actool`/`ibtool` are Xcode's own
///    tools and have no iOS build, so an app that needs them cannot be built
///    on-device at all — see Docs/XCODE-ALTERNATIVE.md.
///  - the JSON project format Xcode 27 can write (`project.xcproj`): only
///    `project.pbxproj` is read.
struct XcodeTargetSummary: Identifiable, Sendable {
    /// The target name, which is unique inside a project.
    let id: String
    let name: String
    /// `PBXProductType` raw value, e.g. `com.apple.product-type.application`.
    /// Empty when the target records none (an aggregate or legacy target).
    let productType: String
    let productName: String
    let bundleIdentifier: String?
    let deploymentTarget: String?
    /// Project-relative paths, as they appear in the project's groups.
    let sourceFiles: [String]
    /// The `.xcconfig` files that feed this target, outermost first.
    let xcconfigPaths: [String]
    /// The merged settings for the target's default configuration.
    let buildSettings: [String: String]
    let configurationNames: [String]
    let defaultConfiguration: String?

    var isApplication: Bool { productType == "com.apple.product-type.application" }
    var containsSwift: Bool { sourceFiles.contains { $0.hasSuffix(".swift") } }
}

struct XcodeProjectSummary: Sendable {
    /// The `.xcodeproj` bundle itself.
    let projectURL: URL
    /// The directory holding it, which is the source root of a relative path.
    let projectDirectory: URL
    let name: String
    let targets: [XcodeTargetSummary]

    var applicationTargets: [XcodeTargetSummary] { targets.filter(\.isApplication) }
}

enum XcodeProjectError: LocalizedError {
    case notFound(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No Xcode project was found at \(path)."
        case .malformed(let reason):
            return "The Xcode project could not be read: \(reason)"
        }
    }
}

enum XcodeProjectReader {
    /// Read `url`, which may be the `.xcodeproj` itself or a directory holding one.
    static func read(at url: URL) throws -> XcodeProjectSummary {
        let projectURL = try locate(from: url)

        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj", isDirectory: false)
        guard let data = try? Data(contentsOf: pbxprojURL),
              let text = String(data: data, encoding: .utf8) else {
            throw XcodeProjectError.malformed("no readable project.pbxproj inside \(projectURL.lastPathComponent)")
        }

        let parsed: PbxValue
        do {
            parsed = try PbxValue.parse(text)
        } catch {
            throw XcodeProjectError.malformed(error.localizedDescription)
        }

        let plist = parsed.dictionaryValue
        let objects = plist["objects"]?.dictionaryValue ?? [:]
        guard let rootID = plist["rootObject"]?.stringValue,
              let root = objects[rootID]?.dictionaryValue,
              !root.isEmpty else {
            throw XcodeProjectError.malformed("the project file names no root object")
        }
        // Xcode < 16 projects often carry no `name`; the bundle's name is then the
        // only name the project has.
        let name = root["name"]?.stringValue ?? projectURL.deletingPathExtension().lastPathComponent

        let paths = groupPaths(root: root, objects: objects)
        let sourceDirectory = projectURL.deletingLastPathComponent()

        let targets = (root["targets"]?.arrayValue ?? []).compactMap { value -> XcodeTargetSummary? in
            guard let targetID = value.stringValue, let target = objects[targetID]?.dictionaryValue else {
                return nil
            }
            return summarize(
                target,
                objects: objects,
                root: root,
                paths: paths,
                sourceDirectory: sourceDirectory
            )
        }

        return XcodeProjectSummary(
            projectURL: projectURL,
            projectDirectory: sourceDirectory,
            name: name,
            targets: targets
        )
    }

    // MARK: - Locating

    private static func locate(from url: URL) throws -> URL {
        if url.pathExtension == "xcodeproj" { return url }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let projects = entries
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let project = projects.first else { throw XcodeProjectError.notFound(url.path) }
        guard projects.count == 1 else {
            // Guessing would compile the wrong app, so say which files are there.
            throw XcodeProjectError.malformed(
                "\(url.lastPathComponent) contains \(projects.count) Xcode projects "
                + "(\(projects.map(\.lastPathComponent).joined(separator: ", "))); name the one to build"
            )
        }
        return project
    }

    // MARK: - Sources

    /// Walk the project's group tree once, so a source file can be reported with the
    /// path it has inside the project rather than the single component its build
    /// phase records.
    private static func groupPaths(root: [String: PbxValue], objects: [String: PbxValue]) -> [String: String] {
        var paths: [String: String] = [:]

        func walk(_ id: String, prefix: String) {
            guard let element = objects[id]?.dictionaryValue else { return }
            let component = element["path"]?.stringValue ?? element["name"]?.stringValue ?? ""
            let full = component.isEmpty
                ? prefix
                : (prefix.isEmpty ? component : prefix + "/" + component)
            paths[id] = full
            for child in element["children"]?.arrayValue ?? [] {
                if let childID = child.stringValue { walk(childID, prefix: full) }
            }
        }

        if let mainGroup = root["mainGroup"]?.stringValue {
            walk(mainGroup, prefix: "")
        }
        return paths
    }

    // MARK: - Targets

    private static func summarize(
        _ target: [String: PbxValue],
        objects: [String: PbxValue],
        root: [String: PbxValue],
        paths: [String: String],
        sourceDirectory: URL
    ) -> XcodeTargetSummary {
        let configurationList = objects[target["buildConfigurationList"]?.stringValue ?? ""]?.dictionaryValue ?? [:]
        let configurationIDs = (configurationList["buildConfigurations"]?.arrayValue ?? []).compactMap(\.stringValue)
        let defaultName = configurationList["defaultConfigurationName"]?.stringValue

        let configurations = configurationIDs.compactMap { id -> [String: PbxValue]? in
            objects[id]?.dictionaryValue
        }
        let chosen = configurations.first { $0["name"]?.stringValue == defaultName } ?? configurations.first

        let projectList = objects[root["buildConfigurationList"]?.stringValue ?? ""]?.dictionaryValue ?? [:]
        let projectConfigurations = (projectList["buildConfigurations"]?.arrayValue ?? [])
            .compactMap { objects[$0.stringValue ?? ""]?.dictionaryValue }
        let projectConfiguration = projectConfigurations.first {
            $0["name"]?.stringValue == chosen?["name"]?.stringValue
        } ?? projectConfigurations.first

        var settings: [String: String] = [:]
        var xcconfigs: [String] = []
        // Xcode's precedence: the project's settings are the base, the target's win
        // over them, and inside each pair the xcconfig is the base.
        if let projectConfiguration {
            let (values, referenced) = resolve(projectConfiguration, objects: objects, sourceDirectory: sourceDirectory)
            settings.merge(values) { _, target in target }
            xcconfigs.append(contentsOf: referenced)
        }
        if let chosen {
            let (values, referenced) = resolve(chosen, objects: objects, sourceDirectory: sourceDirectory)
            settings.merge(values) { _, target in target }
            xcconfigs.append(contentsOf: referenced)
        }

        var sources: [String] = []
        for phaseID in (target["buildPhases"]?.arrayValue ?? []).compactMap(\.stringValue) {
            guard let phase = objects[phaseID]?.dictionaryValue,
                  phase["isa"]?.stringValue == "PBXSourcesBuildPhase" else { continue }
            for fileID in (phase["files"]?.arrayValue ?? []).compactMap(\.stringValue) {
                guard let buildFile = objects[fileID]?.dictionaryValue,
                      let referenceID = buildFile["fileRef"]?.stringValue else { continue }
                // The group tree has the full project-relative path; a build file
                // whose reference is not in it (or is a variant group) at least has
                // its own path.
                let path = paths[referenceID] ?? objects[referenceID]?.dictionaryValue["path"]?.stringValue
                if let path, !path.isEmpty { sources.append(path) }
            }
        }

        let targetName = target["name"]?.stringValue ?? ""
        return XcodeTargetSummary(
            id: targetName,
            name: targetName,
            productType: target["productType"]?.stringValue ?? "",
            productName: settings["PRODUCT_NAME"] ?? targetName,
            bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"],
            deploymentTarget: settings["IPHONEOS_DEPLOYMENT_TARGET"],
            sourceFiles: Array(Set(sources)).sorted(),
            xcconfigPaths: xcconfigs,
            buildSettings: settings,
            configurationNames: configurations.compactMap { $0["name"]?.stringValue },
            defaultConfiguration: chosen?["name"]?.stringValue
        )
    }

    // MARK: - Build settings

    private static func resolve(
        _ configuration: [String: PbxValue],
        objects: [String: PbxValue],
        sourceDirectory: URL
    ) -> ([String: String], [String]) {
        var settings = flatten(configuration["buildSettings"]?.dictionaryValue ?? [:])
        var paths: [String] = []

        guard let referenceID = configuration["baseConfigurationReference"]?.stringValue,
              let reference = objects[referenceID]?.dictionaryValue,
              let relative = reference["path"]?.stringValue else {
            return (settings, paths)
        }

        paths.append(relative)
        let url = sourceDirectory.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (settings, paths) }

        // The xcconfig is the base of its layer: settings written in the project
        // file itself win over it.
        settings.merge(xcconfigSettings(text)) { _, declared in declared }
        return (settings, paths)
    }

    /// `KEY = VALUE` lines, `//` comments and `#include` ignored: enough to see what
    /// a real project's xcconfig says, without pretending to be Xcode's evaluator.
    private static func xcconfigSettings(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { settings[key] = value }
        }
        return settings
    }

    private static func flatten(_ buildSettings: [String: PbxValue]) -> [String: String] {
        var settings: [String: String] = [:]
        for (key, value) in buildSettings {
            if let string = value.stringValue {
                settings[key] = string
            } else if let array = value.arrayValue {
                settings[key] = array.compactMap(\.stringValue).joined(separator: " ")
            }
        }
        return settings
    }
}

// MARK: - OpenStep property list

/// The value tree of an OpenStep property list, which is what a `project.pbxproj`
/// is. Xcode writes dictionaries, arrays, quoted and unquoted strings, hex data,
/// and `/* comments */` between everything.
enum PbxValue {
    case string(String)
    case array([PbxValue])
    case dictionary([String: PbxValue])
    case data(Data)

    /// Values that matter here are strings; anything else is reported as missing.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [PbxValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var dictionaryValue: [String: PbxValue] {
        if case .dictionary(let value) = self { return value }
        return [:]
    }

    static func parse(_ text: String) throws -> PbxValue {
        var scanner = PbxScanner(text)
        let value = try scanner.value()
        return value
    }
}

enum PbxParseError: LocalizedError {
    case unexpectedEnd
    case unexpectedCharacter(Character)
    case unterminated(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedEnd: return "the project file ends in the middle of a value."
        case .unexpectedCharacter(let character): return "unexpected '\(character)' in the project file."
        case .unterminated(let what): return "the project file has an unterminated \(what)."
        }
    }
}

/// Recursive-descent reader for the OpenStep format. The grammar is small enough to
/// own: `{ key = value; … }`, `( value, … )`, quoted and bare strings, `<hex>`, and
/// two comment forms.
private struct PbxScanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    mutating func value() throws -> PbxValue {
        skipTrivia()
        guard index < characters.count else { throw PbxParseError.unexpectedEnd }
        switch characters[index] {
        case "{": return try dictionary()
        case "(": return try array()
        case "\"": return .string(try quotedString())
        case "<": return .data(try hexData())
        default: return .string(try bareString())
        }
    }

    private mutating func dictionary() throws -> PbxValue {
        index += 1  // "{"
        var result: [String: PbxValue] = [:]
        while true {
            skipTrivia()
            guard index < characters.count else { throw PbxParseError.unterminated("dictionary") }
            if characters[index] == "}" {
                index += 1
                return .dictionary(result)
            }
            let key = try value().stringValue ?? ""
            skipTrivia()
            guard index < characters.count, characters[index] == "=" else {
                throw PbxParseError.unterminated("dictionary entry")
            }
            index += 1
            result[key] = try value()
            skipTrivia()
            if index < characters.count, characters[index] == ";" { index += 1 }
        }
    }

    private mutating func array() throws -> PbxValue {
        index += 1  // "("
        var result: [PbxValue] = []
        while true {
            skipTrivia()
            guard index < characters.count else { throw PbxParseError.unterminated("array") }
            if characters[index] == ")" {
                index += 1
                return .array(result)
            }
            result.append(try value())
            skipTrivia()
            if index < characters.count, characters[index] == "," { index += 1 }
        }
    }

    private mutating func quotedString() throws -> String {
        index += 1  // "\""
        var result = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                switch next {
                case "n": result.append("\n"); index += 2
                case "t": result.append("\t"); index += 2
                case "r": result.append("\r"); index += 2
                case "U", "u":
                    let digits = String(characters[index + 2 ..< min(index + 6, characters.count)])
                    if let scalar = UInt32(digits, radix: 16), let unicode = Unicode.Scalar(scalar) {
                        result.unicodeScalars.append(unicode)
                    }
                    index += 6
                case .some(let escaped): result.append(escaped); index += 2
                case .none: throw PbxParseError.unterminated("string")
                }
            } else if character == "\"" {
                index += 1
                return result
            } else {
                result.append(character)
                index += 1
            }
        }
        throw PbxParseError.unterminated("string")
    }

    private mutating func hexData() throws -> Data {
        guard let end = characters[index...].firstIndex(of: ">") else {
            throw PbxParseError.unterminated("data value")
        }
        let digits = String(characters[(index + 1) ..< end]).filter { !$0.isWhitespace }
        index = end + 1

        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var pending: UInt8?
        for character in digits {
            guard let nibble = character.hexDigitValue else { continue }
            if let high = pending {
                bytes.append(high << 4 | UInt8(nibble))
                pending = nil
            } else {
                pending = UInt8(nibble)
            }
        }
        return Data(bytes)
    }

    private mutating func bareString() throws -> String {
        let start = index
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || "=;,(){}\"<>".contains(character) { break }
            if character == "/", index + 1 < characters.count,
               characters[index + 1] == "/" || characters[index + 1] == "*" { break }
            index += 1
        }
        guard index > start else { throw PbxParseError.unexpectedCharacter(characters[index]) }
        return String(characters[start ..< index])
    }

    /// Whitespace and both comment forms, which Xcode sprinkles between everything.
    private mutating func skipTrivia() {
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else {
                return
            }
        }
    }
}
