import Foundation
import DebugTrace

/// Loads the live-patching runtime (`DebugTraceInject`) when a development build
/// carries it, so an app opts in by how it is built, not by what it links.
///
/// `build-and-sign --inject` compiles the runtime with the app's own compiler
/// arguments and embeds it as `Frameworks/DebugTraceInject.dylib`. A build
/// without `--inject`, and every App Store build, has no such file, so nothing
/// loads and no code that loads code ships. The OS only maps the dylib if the
/// team that signed the app signed it.
enum DebugPatchRuntimeLoader {
    static let fileName = "DebugTraceInject.dylib"
    nonisolated(unsafe) private static var attempted = false

    /// Whether the runtime is present, loaded, and has registered its endpoints.
    /// Development builds only; at most one attempt per launch.
    @MainActor
    @discardableResult
    static func loadIfEmbedded(log: DebugLogger, bundle: Bundle = .main) -> Bool {
        guard !attempted, DebugTrace.privacy == .development else { return false }
        attempted = true
        guard let directory = bundle.privateFrameworksPath else { return false }
        let path = (directory as NSString).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            log.error("live patching unavailable: \(reason, privacy: .public)")
            return false
        }
        guard let symbol = dlsym(handle, "debugtrace_inject_register") else {
            log.error("live patching unavailable: runtime has no entry point")
            return false
        }
        typealias Entry = @convention(c) () -> Void
        unsafeBitCast(symbol, to: Entry.self)()
        log.notice("live patching runtime loaded")
        return true
    }
}
