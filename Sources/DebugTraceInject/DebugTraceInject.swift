import Compression
import DebugTrace
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Live code patching for a development build: the `_inject` command loads a
/// dylib the Mac compiled and signed with the developer's own certificate,
/// then runs its optional entry point.
///
/// The patch replaces functions with Swift's `@_dynamicReplacement`, which
/// needs the app built with `-enable-testing`, `-Xfrontend
/// -enable-implicit-dynamic` and `-Xfrontend -enable-private-imports`
/// (`build-and-sign --inject` sets all three). The OS only loads a dylib
/// signed by the team that signed the app, so the bearer token alone can't
/// make the app run code: whoever sends a patch needs the signing key too.
///
/// A separate product so a submission build can leave it unlinked. Code that
/// loads executable code at runtime is not something to ship to the App
/// Store, and `register(on:)` refuses to run in release privacy mode anyway.
///
/// A patch may export `@_cdecl("debugtrace_patch_entry") func() -> UnsafeMutablePointer<CChar>?`,
/// which runs once on the main actor after loading; the C string it returns
/// (allocated with `strdup`) comes back as `output`.
public enum DebugTraceInject {
    public typealias Entry = @convention(c) () -> UnsafeMutablePointer<CChar>?

    /// Patches loaded this run, oldest first. A loaded dylib stays loaded, so
    /// to undo a change send a patch that restores the old body.
    @MainActor public private(set) static var loaded: [LoadedPatch] = []

    /// Bumped on every load. A SwiftUI view that wants to redraw after a
    /// patch reads it (`.id(DebugTraceInject.generation)`).
    @MainActor public private(set) static var generation = 0

    /// Called after each load, on the main actor, for an app that needs to
    /// rebuild something a patch can't reach by itself.
    @MainActor public static var onLoad: (@MainActor (LoadedPatch) -> Void)?

    public struct LoadedPatch: Sendable, Encodable {
        public let label: String
        public let bytes: Int
        public let loadedAt: String
    }

    static let maxPatchBytes = 16 << 20

    /// Registers `_inject` on `surface`. Call once at launch, next to
    /// `DebugTraceServer.startIfRequested()`. Does nothing in release mode.
    @MainActor
    public static func register(on surface: DebugSurface = .shared) {
        guard DebugTrace.privacy == .development else { return }
        surface.register(.command(
            "_inject",
            "Load a patch built on the Mac and run its entry point. Live code changes: build-and-sign --inject builds the app so Swift functions can be replaced, and the apps MCP `inject` tool compiles, signs and sends the patch for you. Call this directly only with a dylib signed by the team that signed the app.",
            parameters: [
                .string("patch", "the signed dylib, base64 (deflated first when encoding=deflate)", required: true),
                .string("label", "what the patch is, for the load history", default: "patch"),
                .string("encoding", "raw: the dylib's bytes; deflate: raw DEFLATE (RFC 1951) of them, for a patch whose symbol names (a large SwiftUI body's types) would not fit the request limit", default: "raw", choices: ["raw", "deflate"]),
                .integer("bytes", "encoding=deflate: the dylib's size once inflated, required so the output buffer is bounded", range: 1...maxPatchBytes),
            ],
            destructive: true,
            timeout: .seconds(60)
        ) { arguments in
            let encoded = try arguments.requireString("patch")
            guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
                throw DebugError.invalidArgument("patch is not base64",
                                                 hint: "send the dylib's bytes base64-encoded")
            }
            if arguments.string("encoding") == "deflate" {
                guard let size = arguments.int("bytes") else {
                    throw DebugError.invalidArgument("encoding=deflate needs bytes", hint: "send the dylib's uncompressed size as `bytes`")
                }
                return try load(try inflate(data, expecting: size), label: arguments.string("label") ?? "patch")
            }
            return try load(data, label: arguments.string("label") ?? "patch")
        })
        surface.register(.query(
            "_patches", "Patches loaded into this run, oldest first. Empty after a relaunch: a patch lives only as long as the process.",
            trace: .never
        ) { _ in
            PatchList(patches: Self.loaded, generation: Self.generation)
        })
    }

    struct PatchList: Encodable {
        let patches: [LoadedPatch]
        let generation: Int
    }

    struct LoadReply: Encodable {
        let loaded: LoadedPatch
        let generation: Int
        let output: String?
        let patchCount: Int
    }

    /// Raw DEFLATE (what Apple's Compression framework calls `COMPRESSION_ZLIB`) into a buffer of
    /// exactly `size` bytes. One byte more is allowed for, so a stream that inflates past `size`
    /// is an error and not a silently cut patch.
    static func inflate(_ data: Data, expecting size: Int) throws -> Data {
        var output = Data(count: size + 1)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else {
            throw DebugError.invalidArgument("the deflated patch inflates to \(written == size + 1 ? "more than" : "\(written) bytes, not") \(size) bytes",
                                             hint: "send the dylib's exact uncompressed size as `bytes`, deflated as raw DEFLATE (zlib wbits=-15)")
        }
        output.removeLast()
        return output
    }

    /// Writes `data` where the app can load it, `dlopen`s it, and runs its entry.
    @MainActor
    static func load(_ data: Data, label: String) throws -> LoadReply {
        guard DebugTrace.privacy == .development else {
            throw DebugError(.forbidden, "patching does not run in release builds",
                             hint: "install a development build from build-and-sign --inject")
        }
        guard data.count <= maxPatchBytes else {
            throw DebugError(.tooLarge, "patch is \(data.count) bytes; the limit is \(maxPatchBytes)",
                             hint: "patch fewer files at once")
        }
        // A fresh name per load: dyld caches by path, and a changed file under
        // an old name would not be loaded again.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("debugtrace-patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("patch\(loaded.count + 1)-\(UUID().uuidString.prefix(8)).dylib")
        try data.write(to: url, options: .atomic)
        guard let handle = dlopen(url.path, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw DebugError(.failedPrecondition, "the app refused the patch: \(reason)",
                             hint: Self.hint(forLoadFailure: reason))
        }
        var output: String?
        if let symbol = dlsym(handle, "debugtrace_patch_entry") {
            let entry = unsafeBitCast(symbol, to: Entry.self)
            if let result = entry() {
                output = String(cString: result)
                free(result)
            }
        }
        let patch = LoadedPatch(label: label, bytes: data.count, loadedAt: DebugTime.iso(Date()))
        loaded.append(patch)
        generation += 1
        onLoad?(patch)
        // DebugTraceUI's `@PatchRefresh` and friends listen by name: the runtime is embedded, not linked.
        NotificationCenter.default.post(name: Notification.Name("com.illixion.debugtrace.patchLoaded"), object: nil)
        return LoadReply(loaded: patch, generation: generation, output: output, patchCount: loaded.count)
    }

    static func hint(forLoadFailure reason: String) -> String {
        if reason.contains("code signature") {
            return "the patch must be signed with the same development certificate as the app; use the apps MCP `inject` tool, or build-and-sign --sign-dylib"
        }
        if reason.contains("symbol not found") {
            return "the running app was not built with build-and-sign --inject, or the patch targets a function this build doesn't have; rebuild and relaunch with --inject"
        }
        return "rebuild with build-and-sign --inject and try again"
    }
}

/// The C entry for the runtime that `build-and-sign --inject` embeds in the app
/// bundle, so an app that never links `DebugTraceInject` can still be patched in
/// a build made for it: the debug server finds the dylib in the bundle's
/// Frameworks, loads it and calls this. A no-op in release privacy mode.
@_cdecl("debugtrace_inject_register")
nonisolated public func debugtrace_inject_register() {
    MainActor.assumeIsolated { DebugTraceInject.register() }
}
