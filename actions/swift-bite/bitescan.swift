// Command bitescan reports the test functions of Swift test files, their line
// spans, and whether they carry a `bite-exempt:` opt-out — the facts
// swift-bite.sh needs and the ones a regex over source cannot get right (a `}`
// inside a raw or multiline string literal, a trailing closure, a macro).
//
// It parses with the toolchain's OWN parser: sourcekitdInProc, loaded straight
// out of the active toolchain with dlopen. Zero third-party dependencies, no
// package build — `swiftc -import-objc-header skdshim.h bitescan.swift` from any
// directory, in seconds, and the grammar can never lag the compiler the fleet
// builds with. (SwiftSyntax would need a multi-minute package build per run;
// `swiftc -dump-parse` leaves inherited-type names unresolved, so an XCTestCase
// subclass is invisible there.)
//
// Usage:
//
//	bitescan FILE...
//
// Output: one TSV record per test function, in source order, per file:
//
//	FILE \t KIND \t ID \t STARTLINE \t ENDLINE \t EXEMPT \t CONFIDENCE \t DISPLAY
//
// KIND is `xctest` or `swift-testing`. ID is the test's identity BELOW the
// module: `ClassName/testMethod` for XCTest, `Suite/Path/funcName()` (or a bare
// `funcName()`) for swift-testing — the caller prepends the target name, because
// only Package.swift knows it. STARTLINE includes the function's attributes: a
// `.disabled(...)` trait edit is a change to the test.
//
// DISPLAY is `-`, or the display name from `@Test("…")` — `swift test list` and
// `--filter` speak the function ID, but the runtime's verdict lines print the
// display name in quotes (measured), so the judge needs both.
//
// EXEMPT is `-`, or the (non-empty) reason following `bite-exempt:` in the
// comment block directly above the function. A `bite-exempt:` with no reason is
// a hard error (exit 2): the annotation costs an explanation, otherwise it
// becomes a reflex.
//
// CONFIDENCE is `run`, or `maybe` for an XCTest-shaped method whose containing
// type this batch cannot prove to be an XCTestCase subclass (a method added via
// `extension SomeTests` when the class declaration was not handed to the same
// invocation). The caller checks `maybe` rows against `swift test list` instead
// of trusting them.
//
// All files of one invocation form ONE resolution batch: an `extension FooTests`
// in file A is resolved against `class FooTests: XCTestCase` in file B when both
// are passed together. Swift-testing needs no such resolution — `@Test` travels
// on the function itself.
//
// Exit: 0 ok (including a file with no test functions), 2 parse error or an
// unexplained opt-out.
import Foundation

// exemptMarker opts a test function out of the gate. Spelled out in full so
// `grep -r bite-exempt` finds both ends of the contract.
let exemptMarker = "bite-exempt:"

// ---------------------------------------------------------------- sourcekitd

typealias Obj = UnsafeMutableRawPointer

let devDir: String = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    p.arguments = ["-p"]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { die("cannot run xcode-select: \(error)") }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: out, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}()

func die(_ message: String) -> Never {
    FileHandle.standardError.write("bitescan: \(message)\n".data(using: .utf8)!)
    exit(2)
}

// Xcode nests the toolchain; the Command Line Tools keep usr/lib at the top.
let skdHandle: UnsafeMutableRawPointer = {
    let candidates = [
        devDir + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitdInProc.framework/sourcekitdInProc",
        devDir + "/usr/lib/sourcekitdInProc.framework/sourcekitdInProc",
    ]
    guard let lib = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
          let handle = dlopen(lib, RTLD_NOW) else {
        die("cannot locate sourcekitdInProc under \(devDir)")
    }
    return handle
}()

func sym<T>(_ name: String, _: T.Type) -> T {
    guard let s = dlsym(skdHandle, name) else { die("missing symbol \(name)") }
    return unsafeBitCast(s, to: T.self)
}

let skdInitialize = sym("sourcekitd_initialize", (@convention(c) () -> Void).self)
let skdUID        = sym("sourcekitd_uid_get_from_cstr", (@convention(c) (UnsafePointer<CChar>) -> Obj?).self)
let skdDictCreate = sym("sourcekitd_request_dictionary_create", (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int) -> Obj?).self)
let skdSetUID     = sym("sourcekitd_request_dictionary_set_uid", (@convention(c) (Obj, Obj, Obj) -> Void).self)
let skdSetString  = sym("sourcekitd_request_dictionary_set_string", (@convention(c) (Obj, Obj, UnsafePointer<CChar>) -> Void).self)
let skdSetInt     = sym("sourcekitd_request_dictionary_set_int64", (@convention(c) (Obj, Obj, Int64) -> Void).self)
let skdSendSync   = sym("sourcekitd_send_request_sync", (@convention(c) (Obj) -> Obj?).self)
let skdIsError    = sym("sourcekitd_response_is_error", (@convention(c) (Obj) -> Bool).self)
let skdGetValue   = sym("sourcekitd_response_get_value", skd_response_get_value_f.self)
let skdJSON       = sym("sourcekitd_variant_json_description_copy", skd_variant_json_f.self)

// structure asks for the syntactic layout of one file: the declaration tree
// (names, byte spans, attributes, inherited-type names) plus the syntax map the
// comment scan reads. syntactic_only keeps sourcekitd from trying to type-check
// against modules that are not there.
func structure(of file: String) -> [String: Any]? {
    let req = skdDictCreate(nil, nil, 0)!
    skdSetUID(req, skdUID("key.request")!, skdUID("source.request.editor.open")!)
    skdSetString(req, skdUID("key.name")!, file)
    skdSetString(req, skdUID("key.sourcefile")!, file)
    skdSetInt(req, skdUID("key.syntactic_only")!, 1)
    guard let resp = skdSendSync(req), !skdIsError(resp) else { return nil }
    guard let json = skdJSON(skdGetValue(resp)) else { return nil }
    defer { free(json) }
    let data = Data(bytes: json, count: strlen(json))
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// ------------------------------------------------------------------- helpers

struct SourceFile {
    let path: String
    let bytes: [UInt8]
    let lineStarts: [Int]  // byte offset of each line start, 1-based lines

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        self.path = path
        self.bytes = [UInt8](data)
        var starts = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { starts.append(i + 1) }
        self.lineStarts = starts
    }

    func line(ofOffset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    func text(offset: Int, length: Int) -> String {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
    }
}

// attributeName pulls "@Test" out of "@Test(.disabled(\"x\"))" and normalises a
// module-qualified "@Testing.Test" to its base name.
func attributeName(_ text: String) -> String {
    var name = text.prefix(while: { !"( \t\n".contains($0) })
    if let dot = name.lastIndex(of: ".") { name = name[name.index(after: dot)...] }
    return name.hasPrefix("@") ? String(name) : "@" + name
}

// displayName pulls "pretty" out of "@Test(\"pretty\", arguments: …)": a display
// name is the attribute's leading plain string literal. Raw or multiline string
// syntax there returns "-" — the judge then simply lacks the display alias, and
// the collective arms still cover the test. Tabs would forge a TSV field and a
// newline a record, so both collapse to spaces.
func displayName(_ text: String) -> String {
    guard let open = text.firstIndex(of: "("), text[text.index(after: open)...].first == "\"" else { return "-" }
    var out = ""
    var escaped = false
    for ch in text[text.index(open, offsetBy: 2)...] {
        if escaped {
            switch ch {
            case "n": out.append(" ")
            case "t": out.append(" ")
            default: out.append(ch)
            }
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "\"" {
            let trimmed = out.replacingOccurrences(of: "\t", with: " ")
            return trimmed.isEmpty ? "-" : trimmed
        } else {
            out.append(ch)
        }
    }
    return "-"
}

struct Record {
    let file: String
    let kind: String        // xctest | swift-testing
    let id: String          // below the module: Class/testMethod or Suite/fn()
    let startLine: Int
    let endLine: Int
    var exempt: String      // "-" or the reason
    let confidence: String  // run | maybe
    let display: String     // "-" or the @Test("…") display name
}

struct CommentSpan {
    let startLine: Int
    let endLine: Int
    let text: String
}

// ----------------------------------------------------------------- the walk

var records: [Record] = []
var rc: Int32 = 0

// Pass 1 across the whole batch: which class names are XCTestCase subclasses?
// (The fleet subclasses XCTestCase directly; an intermediate base class in
// another, unscanned file is an accepted limitation — those methods surface as
// `maybe` via the extension path only when the extension is in the diff.)
var xctestClasses = Set<String>()

struct Parsed {
    let source: SourceFile
    let root: [String: Any]
    let comments: [CommentSpan]
}
var parsed: [Parsed] = []

let arguments = CommandLine.arguments.dropFirst()
if arguments.isEmpty { die("usage: bitescan FILE...") }

skdInitialize()

for path in arguments {
    guard let source = SourceFile(path: path) else {
        FileHandle.standardError.write("bitescan: cannot read \(path)\n".data(using: .utf8)!)
        rc = 2
        continue
    }
    guard let root = structure(of: path) else {
        FileHandle.standardError.write("bitescan: sourcekitd cannot parse \(path)\n".data(using: .utf8)!)
        rc = 2
        continue
    }
    var comments: [CommentSpan] = []
    for entry in root["key.syntaxmap"] as? [[String: Any]] ?? [] {
        guard let kind = entry["key.kind"] as? String, kind.contains("comment"),
              let offset = entry["key.offset"] as? Int, let length = entry["key.length"] as? Int
        else { continue }
        comments.append(CommentSpan(
            startLine: source.line(ofOffset: offset),
            endLine: source.line(ofOffset: max(offset, offset + length - 1)),
            text: source.text(offset: offset, length: length)))
    }
    parsed.append(Parsed(source: source, root: root, comments: comments))

    func collectClasses(_ node: [String: Any]) {
        if node["key.kind"] as? String == "source.lang.swift.decl.class",
           let name = node["key.name"] as? String {
            let inherited = (node["key.inheritedtypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["key.name"] as? String }
            if inherited.contains("XCTestCase") { xctestClasses.insert(name) }
        }
        for child in node["key.substructure"] as? [[String: Any]] ?? [] { collectClasses(child) }
    }
    collectClasses(root)
}

// exemption reads the contiguous comment block that ends on the line directly
// above `line` and returns the bite-exempt reason, "-", or nil for an
// unexplained marker. Only that block counts: a marker buried in the body would
// let an opt-out hide anywhere.
func exemption(above line: Int, in comments: [CommentSpan], file: String, id: String) -> String? {
    var blockText: [String] = []
    var expectedEnd = line - 1
    for span in comments.reversed() where span.endLine <= expectedEnd {
        if span.endLine < expectedEnd { break }
        blockText.insert(span.text, at: 0)
        expectedEnd = span.startLine - 1
    }
    for lineText in blockText.joined(separator: "\n").split(separator: "\n") {
        guard let range = lineText.range(of: exemptMarker) else { continue }
        var reason = String(lineText[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if reason.hasSuffix("*/") { reason = String(reason.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if reason.isEmpty {
            FileHandle.standardError.write(
                "bitescan: \(file): \(id) carries `\(exemptMarker)` with no reason — state what the test pins instead of a fix\n"
                    .data(using: .utf8)!)
            return nil
        }
        // The record is TSV; collapsing whitespace keeps a tab from forging a field.
        return reason.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
    return "-"
}

let typeKinds: Set<String> = [
    "source.lang.swift.decl.class",
    "source.lang.swift.decl.struct",
    "source.lang.swift.decl.enum",
    "source.lang.swift.decl.actor",
]
let extensionKinds: Set<String> = [
    "source.lang.swift.decl.extension",
    "source.lang.swift.decl.extension.class",
    "source.lang.swift.decl.extension.struct",
    "source.lang.swift.decl.extension.enum",
]
let functionKinds: Set<String> = [
    "source.lang.swift.decl.function.free",
    "source.lang.swift.decl.function.method.instance",
    "source.lang.swift.decl.function.method.static",
    "source.lang.swift.decl.function.method.class",
]

for p in parsed {
    let source = p.source

    // container: type-name components on the way down ("Outer", "Inner").
    // viaExtension: the outermost hop was an extension, so XCTestCase-ness rides
    // on the batch-wide class table rather than this node's own inheritance.
    func walk(_ node: [String: Any], container: [String], containerIsXCTestCase: Bool) {
        let kind = node["key.kind"] as? String ?? ""
        let children = node["key.substructure"] as? [[String: Any]] ?? []

        if typeKinds.contains(kind) || extensionKinds.contains(kind) {
            guard let name = node["key.name"] as? String else { return }
            // `extension Outer.Inner` names the nested type with dots.
            let components = name.split(separator: ".").map(String.init)
            let inherited = (node["key.inheritedtypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["key.name"] as? String }
            let isCase = inherited.contains("XCTestCase")
                || xctestClasses.contains(name)
                || containerIsXCTestCase
            for child in children {
                walk(child, container: container + components, containerIsXCTestCase: isCase)
            }
            return
        }

        if functionKinds.contains(kind), let name = node["key.name"] as? String,
           let offset = node["key.offset"] as? Int, let length = node["key.length"] as? Int {
            let attributes = (node["key.attributes"] as? [[String: Any]] ?? []).compactMap {
                attr -> (offset: Int, name: String, text: String)? in
                guard let ao = attr["key.offset"] as? Int, let al = attr["key.length"] as? Int
                else { return nil }
                let text = source.text(offset: ao, length: al)
                return (ao, attributeName(text), text)
            }
            let effectiveStart = ([offset] + attributes.map(\.offset)).min()!
            let startLine = source.line(ofOffset: effectiveStart)
            let endLine = source.line(ofOffset: max(offset, offset + length - 1))

            var record: Record?
            if let testAttr = attributes.first(where: { $0.name == "@Test" }) {
                record = Record(
                    file: source.path, kind: "swift-testing",
                    id: (container + [name]).joined(separator: "/"),
                    startLine: startLine, endLine: endLine, exempt: "-", confidence: "run",
                    display: displayName(testAttr.text))
            } else if kind == "source.lang.swift.decl.function.method.instance",
                      name.hasPrefix("test"), name.hasSuffix("()"), !container.isEmpty {
                // XCTest runs zero-argument instance `test…` methods of XCTestCase
                // subclasses. A method whose container this batch cannot vouch for
                // (an extension of a class declared in an unscanned file) is
                // `maybe`: the caller keeps it only if `swift test list` knows it.
                record = Record(
                    file: source.path, kind: "xctest",
                    id: (container + [String(name.dropLast(2))]).joined(separator: "/"),
                    startLine: startLine, endLine: endLine, exempt: "-",
                    confidence: containerIsXCTestCase ? "run" : "maybe",
                    display: "-")
            }
            if var record {
                guard let exempt = exemption(above: startLine, in: p.comments, file: source.path, id: record.id)
                else { rc = 2; return }
                record.exempt = exempt
                records.append(record)
            }
            // No recursion: a nested func inside a test is part of that test.
            return
        }

        for child in children {
            walk(child, container: container, containerIsXCTestCase: containerIsXCTestCase)
        }
    }
    for child in p.root["key.substructure"] as? [[String: Any]] ?? [] {
        walk(child, container: [], containerIsXCTestCase: false)
    }
}

// Print whatever was scanned even on failure: the caller reports the error and a
// partial record set is still more informative than none.
var out = ""
for r in records {
    out += "\(r.file)\t\(r.kind)\t\(r.id)\t\(r.startLine)\t\(r.endLine)\t\(r.exempt)\t\(r.confidence)\t\(r.display)\n"
}
print(out, terminator: "")
exit(rc)
