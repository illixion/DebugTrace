// debugtrace-rewrite: turns "this file before, this file after" into a Swift patch
// of @_dynamicReplacement extensions, for `debugtrace-inject`.
//
//   debugtrace-rewrite --old OLD.swift --new NEW.swift --module M --source-file NAME.swift --out PATCH.swift
//                      [--config BUILD.json] [--built BUILT.swift]
//
// With --built (the file as the app was built), methods that an earlier patch
// added are known: the app has no such symbol to replace, so a change to one,
// or to a patched function that calls one, re-emits the whole accumulated patch
// of the file in this dylib (added methods copied again, every function that
// differs from the build replaced again). Later patches override earlier ones.
//
// Prints a JSON report on stdout. Functions and computed properties whose body
// changed are replaced; new methods and types are copied over as they are;
// everything a patch cannot do (a stored property, an initializer, a changed
// type header) is listed under `unpatchable`, and the caller then tells the
// agent to rebuild instead. With --config (the app's build configuration,
// BuildConfig.swift) each `#if` is first reduced to the branch the app was
// compiled with; without it, or when a condition can't be evaluated, a changed
// `#if` is unpatchable.
//
// Built against the SwiftSyntax that ships inside the Xcode toolchain
// (usr/lib/swift/host), so there is no package to fetch.

import Foundation
import SwiftParser
import SwiftSyntax

struct Report: Encodable {
    var patched: [String] = []
    var added: [String] = []
    var unpatchable: [Problem] = []
    var unchanged = 0
    var removed: [String] = []
    var hasPatch = false
    /// This patch restates everything earlier patches did to the file (see --built).
    var cumulative = false

    struct Problem: Encodable {
        let decl: String
        let reason: String
    }
}

// MARK: - Declaration index

/// One function-like or computed member, found by walking a file.
struct Callable {
    enum Kind { case function, computedProperty }
    let kind: Kind
    /// "Outer.Inner" or an extension's `Type where …`, "" at top level.
    let path: String
    /// What `@_dynamicReplacement(for:)` names: `update(dt:)`, `size`.
    let selector: String
    /// Selector plus the full signature, so an overload or a changed
    /// signature is a different declaration, not an edit.
    let key: String
    let bodyTokens: String
    let node: Syntax
}

/// Everything in a file that a patch cannot replace, keyed so that a change
/// to it can be seen.
struct Shape {
    var parts: [String: String] = [:]
}

func tokens(_ node: some SyntaxProtocol) -> String {
    node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
}

struct Index {
    var callables: [String: Callable] = [:]
    var order: [String] = []
    /// path-qualified declaration -> token text of everything about it that a patch can't change
    var shapes: [String: String] = [:]
    /// top-level and member declarations that are new in a patch as they stand
    var types: [String: Syntax] = [:]
    /// type id -> the path it is declared under ("" at top level)
    var parents: [String: String] = [:]
    /// shape id of a stored property -> what a patch can carry in its place, if anything
    var carryable: [String: Carry] = [:]
    var opaque: [String: String] = [:]
}

/// A new stored property that a patch can still provide to the code it replaces.
struct Carry {
    let path: String
    let label: String
    /// The declaration as the patch's extension should hold it.
    let text: String
}

/// A stored property a patch can supply although the type's layout is fixed: a `static`
/// (extensions may hold those) or a `let` with a type and a value, which patched code
/// can read as a computed property that returns the value. Only patched code sees it.
func carry(_ variable: VariableDeclSyntax, path: String) -> Carry? {
    guard variable.bindings.count == 1, let binding = variable.bindings.first,
          let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
          let value = binding.initializer?.value, binding.accessorBlock == nil,
          variable.attributes.isEmpty else { return nil }
    let label = (path.isEmpty ? "" : path + ".") + name
    if variable.modifiers.contains(where: { $0.name.text == "static" }) {
        return Carry(path: path, label: label, text: variable.description)
    }
    guard variable.bindingSpecifier.text == "let", let type = binding.typeAnnotation,
          !variable.modifiers.contains(where: { ["lazy", "class", "weak", "unowned"].contains($0.name.text) })
    else { return nil }
    return Carry(path: path, label: label + " (as a computed property)",
                 text: "var \(name)\(type.description.trimmingCharacters(in: .whitespacesAndNewlines)) "
                    + "{ \(value.description.trimmingCharacters(in: .whitespacesAndNewlines)) }")
}

func selector(for function: FunctionDeclSyntax) -> String? {
    let name = function.name.text
    // Operators can't be named in @_dynamicReplacement(for:) from an extension reliably.
    guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return nil }
    let labels = function.signature.parameterClause.parameters.map { ($0.firstName.text) + ":" }
    return "\(name)(\(labels.joined()))"
}

func normalizedSignature(_ function: FunctionDeclSyntax) -> String {
    let modifiers = function.modifiers.map { $0.name.text }.filter { ["static", "class", "mutating", "nonmutating"].contains($0) }
    return modifiers.joined(separator: " ") + " " + tokens(function.genericParameterClause ?? GenericParameterClauseSyntax(parameters: [])) + tokens(function.signature)
        + (function.genericWhereClause.map(tokens) ?? "")
}

func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
}

/// The app's build configuration (--config), and the first `#if` it couldn't settle.
let buildConfiguration: ArgumentsBuildConfiguration? = argument("--config").flatMap(loadBuildConfiguration)
var ifConfigProblem: String?

/// The source as the app was compiled: inactive `#if` branches removed when the
/// build configuration is known and every condition in the file evaluates.
func parsed(_ source: String) -> SourceFileSyntax {
    let tree = Parser.parse(source: source)
    guard let buildConfiguration else { return tree }
    return activeOnly(tree, in: buildConfiguration, problem: &ifConfigProblem) ?? tree
}

func index(_ source: String) -> Index {
    var result = Index()
    let tree = parsed(source)
    walk(items: tree.statements.map { Syntax($0.item) }, path: "", into: &result)
    return result
}

func pathComponent(for decl: Syntax) -> String? {
    if let d = decl.as(StructDeclSyntax.self) { return d.name.text }
    if let d = decl.as(ClassDeclSyntax.self) { return d.name.text }
    if let d = decl.as(EnumDeclSyntax.self) { return d.name.text }
    if let d = decl.as(ActorDeclSyntax.self) { return d.name.text }
    if let d = decl.as(ExtensionDeclSyntax.self) {
        let whereClause = d.genericWhereClause.map { " " + tokens($0) } ?? ""
        return tokens(d.extendedType) + whereClause
    }
    return nil
}

func members(of decl: Syntax) -> [Syntax]? {
    func list(_ block: MemberBlockSyntax) -> [Syntax] { block.members.map { Syntax($0.decl) } }
    if let d = decl.as(StructDeclSyntax.self) { return list(d.memberBlock) }
    if let d = decl.as(ClassDeclSyntax.self) { return list(d.memberBlock) }
    if let d = decl.as(EnumDeclSyntax.self) { return list(d.memberBlock) }
    if let d = decl.as(ActorDeclSyntax.self) { return list(d.memberBlock) }
    if let d = decl.as(ExtensionDeclSyntax.self) { return list(d.memberBlock) }
    return nil
}

/// A type's header (name, generics, inheritance) as token text, without its members.
func header(of decl: Syntax) -> String {
    if let d = decl.as(StructDeclSyntax.self) { return tokens(d.with(\.memberBlock, MemberBlockSyntax(members: []))) }
    if let d = decl.as(ClassDeclSyntax.self) { return tokens(d.with(\.memberBlock, MemberBlockSyntax(members: []))) }
    if let d = decl.as(EnumDeclSyntax.self) { return tokens(d.with(\.memberBlock, MemberBlockSyntax(members: []))) }
    if let d = decl.as(ActorDeclSyntax.self) { return tokens(d.with(\.memberBlock, MemberBlockSyntax(members: []))) }
    if let d = decl.as(ExtensionDeclSyntax.self) { return tokens(d.with(\.memberBlock, MemberBlockSyntax(members: []))) }
    return tokens(decl)
}

func walk(items: [Syntax], path: String, into index: inout Index) {
    var ordinal: [String: Int] = [:]
    for item in items {
        func qualified(_ name: String) -> String { path.isEmpty ? name : "\(path).\(name)" }

        if let function = item.as(FunctionDeclSyntax.self) {
            guard let body = function.body, let selector = selector(for: function) else {
                // A protocol requirement, or an operator: nothing to replace, but a
                // changed one is a change a patch can't carry.
                index.shapes[qualified("func " + tokens(function.signature.parameterClause) + " " + function.name.text)] = tokens(function)
                continue
            }
            let key = "\(path)|func|\(selector)|\(normalizedSignature(function))"
            index.callables[key] = Callable(kind: .function, path: path, selector: selector, key: key,
                                            bodyTokens: tokens(body), node: item)
            index.order.append(key)
            continue
        }
        if let variable = item.as(VariableDeclSyntax.self) {
            for binding in variable.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    index.shapes[qualified("var \(tokens(binding.pattern))")] = tokens(binding)
                    continue
                }
                if let block = binding.accessorBlock, isComputed(block), binding.typeAnnotation != nil, variable.bindings.count == 1 {
                    let key = "\(path)|var|\(name)|\(isStatic(variable.modifiers) ? "static" : "")|\(tokens(binding.typeAnnotation!))"
                    index.callables[key] = Callable(kind: .computedProperty, path: path, selector: name, key: key,
                                                    bodyTokens: tokens(block), node: item)
                    index.order.append(key)
                } else {
                    // Stored (with or without observers): its layout and initial value are fixed at build time.
                    index.shapes[qualified("var \(name)")] = tokens(variable)
                    if let carried = carry(variable, path: path) { index.carryable[qualified("var \(name)")] = carried }
                }
            }
            continue
        }
        if let initializer = item.as(InitializerDeclSyntax.self) {
            // Keyed by signature, so adding a member elsewhere doesn't renumber it.
            index.shapes[qualified("init" + tokens(initializer.signature.parameterClause))] = tokens(initializer)
            continue
        }
        if let ifConfig = item.as(IfConfigDeclSyntax.self) {
            index.opaque[qualified("#if \(index.opaque.count)")] = tokens(ifConfig)
            continue
        }
        if let name = pathComponent(for: item), let inner = members(of: item) {
            let count = ordinal[name, default: 0]
            ordinal[name] = count + 1
            let id = qualified(count == 0 ? name : "\(name)#\(count)")
            index.shapes[id + " header"] = header(of: item)
            index.types[id] = item
            index.parents[id] = path
            // Each extension of a type is walked under the same path text, so a
            // method that moves between two extensions of one type is a new declaration.
            walk(items: inner, path: qualified(name), into: &index)
            continue
        }
        if item.is(ImportDeclSyntax.self) { continue }
        // Anything else (typealias, protocol, global, macro): fixed at build time.
        let label = "\(item.kind) \(tokens(item).prefix(60))"
        index.shapes[qualified(label)] = tokens(item)
    }
}

func isComputed(_ block: AccessorBlockSyntax) -> Bool {
    switch block.accessors {
    case .getter: return true
    case .accessors(let list):
        let names = Set(list.map { $0.accessorSpecifier.text })
        return names.contains("get") || names.contains("_read") || names.contains("_modify")
            || (names.contains("set") && !names.contains("didSet"))
    @unknown default: return false
    }
}

// MARK: - Patch generation

/// A stable short tag per source file, so two files patched together never reuse a name.
func fileTag(_ name: String) -> String {
    var hash: UInt32 = 5381
    for byte in name.utf8 { hash = hash &* 33 &+ UInt32(byte) }
    return String(hash, radix: 36)
}

func replacementText(for callable: Callable, number: Int, tag: String) -> String? {
    let name = "__debugtrace_patch_\(tag)_\(number)"
    if let function = callable.node.as(FunctionDeclSyntax.self), let body = function.body {
        let kept = function.modifiers.filter { ["static", "class", "mutating", "nonmutating"].contains($0.name.text) }
            .map { $0.name.text }
        // `class func` in an extension of a class is fine; `final`/`override`/access control are dropped.
        let attributes = function.attributes.description
        var text = attributes + "\n@_dynamicReplacement(for: \(callable.selector))\n"
        text += kept.joined(separator: " ") + " func \(name)"
        text += function.genericParameterClause?.description ?? ""
        text += function.signature.description
        text += function.genericWhereClause?.description ?? ""
        text += body.description
        return text
    }
    if let variable = callable.node.as(VariableDeclSyntax.self), let binding = variable.bindings.first,
       let type = binding.typeAnnotation, let block = binding.accessorBlock {
        let kept = variable.modifiers.filter { ["static", "class"].contains($0.name.text) }.map { $0.name.text }
        return variable.attributes.description
            + "\n@_dynamicReplacement(for: \(callable.selector))\n"
            + kept.joined(separator: " ") + " var \(name)\(type.description)\(block.description)"
    }
    return nil
}

func wrapped(_ body: String, in path: String) -> String {
    path.isEmpty ? body : "extension \(path) {\n\(body)\n}"
}

/// The text of a type-level declaration copied as it is, under its path.
func copiedText(of node: Syntax, path: String) -> String {
    wrapped(node.description, in: path)
}

// MARK: - Main

func argument(_ name: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: name), at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}

guard let oldPath = argument("--old"), let newPath = argument("--new"), let module = argument("--module"),
      let sourceFile = argument("--source-file"), let outPath = argument("--out") else {
    FileHandle.standardError.write(Data("usage: debugtrace-rewrite --old F --new F --module M --source-file NAME --out F\n".utf8))
    exit(2)
}
guard let oldSource = try? String(contentsOfFile: oldPath, encoding: .utf8),
      let newSource = try? String(contentsOfFile: newPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read the sources\n".utf8))
    exit(2)
}

var report = Report()
let old = index(oldSource)
let new = index(newSource)

/// A top-level type that is new in this file comes along whole, members and all,
/// so nothing inside it is a change to existing code.
/// One nested in a type the app already has comes along too, as an extension member.
let newTypes = Set(new.types.keys.filter { id in
    guard old.types[id] == nil, !id.contains("#") else { return false }
    let parent = new.parents[id] ?? ""
    return parent.isEmpty ? !id.contains(".") : old.types[parent] != nil
})
func belongsToNewType(_ id: String) -> Bool {
    newTypes.contains { id == $0 || id.hasPrefix($0 + ".") || id.hasPrefix($0 + " ") }
}

/// Says what can't be done and what to do instead, because "rebuild" alone sends an agent off to rebuild.
func reason(forChanged id: String, isNew: Bool) -> String {
    if id.hasSuffix(" header") {
        return "a type's inheritance, generics or attributes changed, and a patch cannot change what a type is: leave this type as it was, "
            + "put the new version in a new type (a new type comes along) and patch the code that uses it to use that"
    }
    if id.contains("init(") || id.contains(".init") {
        return "an initializer is fixed at build time: leave it, and set what the new code needs in a patched method or a new type"
    }
    if isNew && (id.contains("var ") || id.contains("Decl")) {
        return "a new stored property can't be added to a type the app already has: use a `static let`, a `let name: Type = value` "
            + "constant, a computed property, or keep the state in a new type"
    }
    return isNew ? "a new declaration the existing code can't see: put it inside a patched method, or in a new type"
                 : "a stored property's value or another declaration changed, which is fixed at build time"
}

// What a patch can't carry: any non-callable thing that differs.
var carried: [Carry] = []
for (id, text) in new.shapes where old.shapes[id] != text && !belongsToNewType(id) {
    if old.shapes[id] == nil, let carry = new.carryable[id] {
        carried.append(carry)
        continue
    }
    report.unpatchable.append(.init(decl: id, reason: reason(forChanged: id, isNew: old.shapes[id] == nil)))
}
for (id, text) in new.opaque where old.opaque[id] != text && !belongsToNewType(id) {
    report.unpatchable.append(.init(decl: id, reason: ifConfigProblem.map { "inside an #if whose condition couldn't be evaluated for this build (\($0))" }
        ?? "inside an #if block, and the build configuration wasn't given"))
}
for id in old.shapes.keys where new.shapes[id] == nil && !id.hasSuffix(" header") {
    report.unpatchable.append(.init(decl: id, reason: "a stored property or declaration was removed"))
}

var body = ""
var number = 0
var addedPaths = Set<String>()

/// What the running app has as built, when known. A callable that the live file
/// has and the build lacks was added by an earlier patch, so it exists only in
/// that patch's dylib and cannot be a @_dynamicReplacement target.
let built: Index? = argument("--built").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map(index)
let earlierAdded = Set(old.callables.keys.filter { built != nil && built!.callables[$0] == nil })
let cumulative = !earlierAdded.isEmpty
if cumulative { report.cumulative = true }

for key in new.order {
    guard let callable = new.callables[key] else { continue }
    if belongsToNewType(callable.path) { continue }
    if cumulative, let built = built {
        // This patch is compiled against the app alone: whatever an earlier patch
        // added or replaced is restated, so that code calling it still resolves.
        let label = (callable.path.isEmpty ? "" : callable.path + ".") + callable.selector
        if let original = built.callables[key] {
            if original.bodyTokens == callable.bodyTokens {
                report.unchanged += 1
                continue
            }
            number += 1
            guard let text = replacementText(for: callable, number: number, tag: fileTag(sourceFile)) else { continue }
            body += wrapped(text, in: callable.path) + "\n\n"
            report.patched.append(label)
        } else if built.types[callable.path] != nil || callable.path.isEmpty {
            body += wrapped(callable.node.description, in: callable.path) + "\n\n"
            report.added.append(label)
            addedPaths.insert(callable.path)
        }
        continue
    }
    if let before = old.callables[key] {
        if before.bodyTokens == callable.bodyTokens {
            report.unchanged += 1
            continue
        }
        number += 1
        guard let text = replacementText(for: callable, number: number, tag: fileTag(sourceFile)) else { continue }
        body += wrapped(text, in: callable.path) + "\n\n"
        report.patched.append((callable.path.isEmpty ? "" : callable.path + ".") + callable.selector)
    } else {
        // New to this file: a new method, or an old one whose signature changed.
        // Copied as it is; only patched code can call it.
        let label = (callable.path.isEmpty ? "" : callable.path + ".") + callable.selector
        if callable.path.isEmpty == false, old.types.keys.contains(where: { $0 == callable.path }) == false,
           new.types[callable.path] == nil {
            report.unpatchable.append(.init(decl: label, reason: "its type is not declared in this file"))
            continue
        }
        body += wrapped(callable.node.description, in: callable.path) + "\n\n"
        report.added.append(label)
        addedPaths.insert(callable.path)
    }
}
for key in old.order where new.callables[key] == nil {
    report.removed.append((old.callables[key]!.path.isEmpty ? "" : old.callables[key]!.path + ".") + old.callables[key]!.selector)
}
// A type that is new in the file comes along whole: at top level as it is, nested as a member of its parent.
for id in newTypes.sorted() {
    guard let node = new.types[id] else { continue }
    body += wrapped(node.description, in: new.parents[id] ?? "") + "\n\n"
    report.added.append(id)
}
for item in carried.sorted(by: { $0.label < $1.label }) {
    body += wrapped(item.text, in: item.path) + "\n\n"
    report.added.append(item.label)
}

let importLines = parsed(newSource).statements.compactMap { $0.item.as(ImportDeclSyntax.self) }
    .map { $0.description.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.hasSuffix(" \(module)") }
var output = "// Generated by debugtrace-rewrite from \(sourceFile). Not source.\n"
output += "@_private(sourceFile: \"\(sourceFile)\") import \(module)\n"
output += Array(Set(importLines)).sorted().joined(separator: "\n") + "\n\n"
output += body
report.hasPatch = !report.patched.isEmpty || !report.added.isEmpty
try? output.write(toFile: outPath, atomically: true, encoding: .utf8)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
print(String(decoding: try encoder.encode(report), as: UTF8.self))
