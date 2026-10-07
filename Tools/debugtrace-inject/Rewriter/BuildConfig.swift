// The build configuration the running app was compiled with, so `#if` can be
// evaluated the way the compiler did: only the active branch of each `#if` is
// what the app runs, and only that branch is diffed and patched.
//
// `debugtrace-inject` writes it as JSON from the module's recorded compiler
// arguments (target triple, -D conditions, -swift-version, feature flags, the
// SDK and module search paths) and passes it with --config.

import Foundation
import SwiftIfConfig
import SwiftSyntax

struct RecordedBuild: Decodable {
    /// From the -target triple: "visionOS", "arm64", "simulator" or "".
    var os: String
    var arch: String
    var environment: String
    var conditions: [String]
    var features: [String]
    var languageVersion: [Int]
    var compilerVersion: [Int]
    /// Where `canImport` looks: -I and -F paths, then the SDK's frameworks
    /// and Swift modules.
    var importPaths: [String]
    var frameworkPaths: [String]
    var sdk: String
    /// Clang modules the SDK's module maps declare (Darwin, os, zlib).
    var sdkModules: [String]?
}

/// A condition this can't settle (an unknown attribute, say) throws: the
/// caller then treats that file's `#if`s as it did before, opaque.
struct UnknownCondition: Error, CustomStringConvertible {
    let description: String
}

struct ArgumentsBuildConfiguration: BuildConfiguration {
    let build: RecordedBuild

    /// Every spelling the compiler accepts for the target's OS.
    private var osNames: Set<String> {
        switch build.os {
        case "visionOS": ["visionOS", "xrOS"]
        case "macOS": ["macOS", "OSX"]
        default: [build.os]
        }
    }

    func isCustomConditionSet(name: String) throws -> Bool { build.conditions.contains(name) }
    func hasFeature(name: String) throws -> Bool { build.features.contains(name) }
    func hasAttribute(name: String) throws -> Bool {
        // The toolchain that compiles the patch is the one that built the app,
        // and it is current: an attribute the source asks about exists.
        true
    }

    func canImport(importPath: [(TokenSyntax, String)], version: CanImportVersion) throws -> Bool {
        guard case .unversioned = version else {
            throw UnknownCondition(description: "a versioned canImport")
        }
        let name = importPath.first?.1 ?? ""
        let fm = FileManager.default
        var candidates: [String] = []
        for dir in build.importPaths {
            candidates += ["\(dir)/\(name).swiftmodule", "\(dir)/\(name).framework", "\(dir)/\(name).modulemap",
                           "\(dir)/\(name)/module.modulemap"]
        }
        for dir in build.frameworkPaths { candidates.append("\(dir)/\(name).framework") }
        if !build.sdk.isEmpty {
            candidates += ["\(build.sdk)/System/Library/Frameworks/\(name).framework",
                           "\(build.sdk)/System/Library/SubFrameworks/\(name).framework",
                           "\(build.sdk)/usr/lib/swift/\(name).swiftmodule",
                           "\(build.sdk)/usr/lib/swift/\(name).swiftinterface"]
        }
        if candidates.contains(where: fm.fileExists(atPath:)) { return true }
        if let sdkModules = build.sdkModules {
            // Searched everywhere the compiler looks: not there means not there,
            // as `#if canImport(AppKit)` on visionOS should find.
            return sdkModules.contains(name)
        }
        throw UnknownCondition(description: "canImport(\(name))")
    }

    func isActiveTargetOS(name: String) throws -> Bool { osNames.contains(name) }
    func isActiveTargetArchitecture(name: String) throws -> Bool { name == build.arch }
    func isActiveTargetEnvironment(name: String) throws -> Bool { name == build.environment }
    func isActiveTargetRuntime(name: String) throws -> Bool { name == "_ObjC" }
    func isActiveTargetPointerAuthentication(name: String) throws -> Bool {
        name == "_arm64e" && build.arch == "arm64e"
    }
    func isActiveTargetObjectFormat(name: String) throws -> Bool { name == "MachO" }
    var targetPointerBitWidth: Int { 64 }
    var targetAtomicBitWidths: [Int] { [8, 16, 32, 64, 128] }
    var endianness: Endianness { .little }
    var languageVersion: VersionTuple { VersionTuple(parsing: build.languageVersion) }
    var compilerVersion: VersionTuple { VersionTuple(parsing: build.compilerVersion) }
}

extension VersionTuple {
    init(parsing components: [Int]) {
        self = VersionTuple(components: components.isEmpty ? [6] : components)
    }
}

func loadBuildConfiguration(_ path: String) -> ArgumentsBuildConfiguration? {
    guard let data = FileManager.default.contents(atPath: path),
          let build = try? JSONDecoder().decode(RecordedBuild.self, from: data) else { return nil }
    return ArgumentsBuildConfiguration(build: build)
}

/// The file as the running app has it: each `#if` reduced to its active branch.
/// Nil when a condition couldn't be evaluated; the reason goes in `problem`.
func activeOnly(_ tree: SourceFileSyntax, in configuration: ArgumentsBuildConfiguration,
                problem: inout String?) -> SourceFileSyntax? {
    let (result, diagnostics) = tree.removingInactive(in: configuration)
    if let first = diagnostics.first {
        problem = first.message
        return nil
    }
    return result.as(SourceFileSyntax.self)
}
