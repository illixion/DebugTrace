import DebugTrace
import DebugTraceSampler
import Darwin
import Foundation

/// `_profile`: a sampling profiler over the debug server, for "where does the
/// time go" without Instruments or a debugger. A background thread suspends
/// each sampled thread for a few microseconds, copies its stack by walking
/// frame pointers (`DebugTraceSampler`, in C so nothing it runs can deadlock on
/// a lock the frozen thread holds), and resumes it. Symbols come from `dladdr`
/// afterwards, off the main thread, with Swift names demangled.
///
/// Lives in the server product, not `DebugTrace`, so an App Store build (which
/// leaves the server unlinked) carries no code that suspends threads.
enum DebugProfiler {
    static let maxDepth = 64

    @MainActor
    static var endpoint: DebugEndpoint {
        .query(
            "_profile",
            "Sample where threads spend their time for a few seconds, then report it: per thread, how often it was busy rather than waiting, the functions most often running (self) and on the stack (inclusive), and the hottest stacks. threads=main (default) samples the main thread; threads=all samples every thread, which is what a renderer or game loop on its own thread needs. Percentages are of that thread's samples. The app keeps running while it samples; each sample pauses the sampled thread for a few microseconds (`overheadMs` totals it).",
            parameters: [
                .number("seconds", "how long to sample", default: 2, range: 0.2...10),
                .number("intervalMs", "time between samples of each thread", default: 2, range: 0.5...50),
                .string("threads", "main or all", default: "main", choices: ["main", "all"]),
                .integer("limit", "rows per list", default: 12, range: 1...50),
            ],
            trace: .never,
            timeout: .seconds(30)
        ) { arguments in
            let options = Options(seconds: arguments.double("seconds") ?? 2,
                                  intervalMs: arguments.double("intervalMs") ?? 2,
                                  allThreads: arguments.string("threads") == "all",
                                  limit: arguments.int("limit") ?? 12,
                                  mainThread: pthread_mach_thread_np(pthread_self()))
            return await withCheckedContinuation { continuation in
                let thread = Thread { continuation.resume(returning: run(options)) }
                thread.name = "DebugTrace profiler"
                thread.qualityOfService = .userInteractive
                thread.start()
            }
        }
    }

    struct Options: Sendable {
        let seconds: Double
        let intervalMs: Double
        let allThreads: Bool
        let limit: Int
        let mainThread: thread_act_t
    }

    struct Report: Encodable, Sendable {
        struct Row: Encodable, Sendable {
            let function: String
            let image: String
            let samples: Int
            let percent: Double
        }
        struct Stack: Encodable, Sendable {
            let samples: Int
            let percent: Double
            /// Outermost first, ending at the function that was running.
            let frames: [String]
        }
        struct ThreadReport: Encodable, Sendable {
            let name: String
            let samples: Int
            /// Samples not parked in a wait (mach_msg, a condition, a semaphore).
            let busyPercent: Double
            /// Busy samples only.
            let selfTop: [Row]
            let inclusiveTop: [Row]
            let hotStacks: [Stack]
        }
        let seconds: Double
        let intervalMs: Double
        let samples: Int
        let overheadMs: Double
        let threads: [ThreadReport]
        let note: String?
    }

    // MARK: Sampling

    private struct Sample {
        let thread: Int
        let start: Int
        let count: Int
    }

    private static func run(_ options: Options) -> Report {
        let me = pthread_mach_thread_np(pthread_self())
        var names: [String] = []
        var nameIndex: [thread_act_t: Int] = [:]
        var bounds: [thread_act_t: dt_stack_bounds] = [:]
        var frames: [UInt64] = []
        var samples: [Sample] = []
        let estimate = Int(options.seconds * 1000 / options.intervalMs) * (options.allThreads ? 8 : 1)
        frames.reserveCapacity(min(estimate, 20_000) * 32)
        samples.reserveCapacity(min(estimate, 20_000))
        let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: maxDepth)
        defer { buffer.deallocate() }

        var targets: [thread_act_t] = []
        var owned: [thread_act_t] = []
        func refreshTargets() {
            for port in owned { mach_port_deallocate(mach_task_self_, port) }
            owned = []
            guard options.allThreads else { targets = [options.mainThread]; return }
            var list: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
                targets = [options.mainThread]
                return
            }
            owned = (0..<Int(count)).map { list[$0] }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
            targets = owned.filter { $0 != me }
        }
        func index(of thread: thread_act_t) -> Int {
            if let known = nameIndex[thread] { return known }
            let name = threadName(thread, main: options.mainThread)
            let index = names.firstIndex(of: name) ?? { names.append(name); return names.count - 1 }()
            nameIndex[thread] = index
            return index
        }

        refreshTargets()
        let interval = options.intervalMs / 1000
        let end = Date().addingTimeInterval(options.seconds)
        var overhead: Double = 0
        var round = 0
        while Date() < end, samples.count < 20_000 {
            if options.allThreads, round > 0, round % 50 == 0 { refreshTargets() }
            round += 1
            let started = Date()
            for thread in targets {
                let range = bounds[thread] ?? { let b = dt_stack_bounds_of(thread); bounds[thread] = b; return b }()
                let t0 = mach_absolute_time()
                let count = Int(dt_backtrace(thread, range, buffer, Int32(maxDepth)))
                overhead += seconds(mach_absolute_time() - t0)
                guard count > 0 else { continue }
                samples.append(Sample(thread: index(of: thread), start: frames.count, count: count))
                frames.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))
            }
            let rest = interval - Date().timeIntervalSince(started)
            if rest > 0 { Thread.sleep(forTimeInterval: rest) }
        }
        for port in owned { mach_port_deallocate(mach_task_self_, port) }
        return summarize(samples: samples, frames: frames, names: names, options: options,
                         overheadMs: overhead * 1000)
    }

    private static func threadName(_ thread: thread_act_t, main: thread_act_t) -> String {
        if thread == main { return "main" }
        var info = thread_identifier_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
        let id = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        } == KERN_SUCCESS ? info.thread_id : 0
        // Unnamed threads (dispatch workers, mostly) are told apart by id: one
        // busy worker must not be averaged into a dozen idle ones.
        let unnamed = "unnamed thread \(id)"
        guard let pthread = pthread_from_mach_thread_np(thread) else { return unnamed }
        var buffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread, &buffer, buffer.count)
        let name = String(cString: buffer)
        return name.isEmpty ? unnamed : name
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    // MARK: Summary

    /// Leaf functions that mean the thread is parked, not working.
    static let waits: Set<String> = [
        "mach_msg2_trap", "mach_msg_trap", "mach_msg_overwrite", "__psynch_cvwait", "__psynch_mutexwait",
        "__psynch_rw_rdlock", "__psynch_rw_wrlock", "__workq_kernreturn", "__semwait_signal",
        "semaphore_wait_trap", "semaphore_timedwait_trap", "__ulock_wait", "__ulock_wait2", "kevent_id",
        "kevent_qos", "kevent64", "__select", "poll", "__sigsuspend", "mach_wait_until", "__wait4",
        "__recvfrom", "__recvmsg", "read", "__read_nocancel", "__pselect", "__accept",
    ]

    private struct Symbol {
        let function: String
        let image: String
    }

    private static func summarize(samples: [Sample], frames: [UInt64], names: [String], options: Options,
                                  overheadMs: Double) -> Report {
        var cache: [UInt64: Symbol] = [:]
        func symbol(_ address: UInt64, leaf: Bool) -> Symbol {
            // A return address points after the call; the call is what ran.
            let lookup = leaf ? address : address &- 1
            if let known = cache[lookup] { return known }
            let resolved = resolve(lookup)
            cache[lookup] = resolved
            return resolved
        }

        var threads: [Report.ThreadReport] = []
        for (index, name) in names.enumerated() {
            let mine = samples.filter { $0.thread == index }
            guard !mine.isEmpty else { continue }
            var selfCounts: [String: (Symbol, Int)] = [:]
            var inclusive: [String: (Symbol, Int)] = [:]
            var stacks: [[String]: Int] = [:]
            var busy = 0
            for sample in mine {
                let symbols = (0..<sample.count).map { symbol(frames[sample.start + $0], leaf: $0 == 0) }
                let leaf = symbols[0]
                // No user pc: the thread is in the kernel or not started yet.
                if waits.contains(leaf.function) || frames[sample.start] == 0 { continue }
                busy += 1
                selfCounts[leaf.function, default: (leaf, 0)].1 += 1
                for function in Set(symbols.map(\.function)) {
                    let symbol = symbols.first { $0.function == function }!
                    inclusive[function, default: (symbol, 0)].1 += 1
                }
                stacks[Array(symbols.prefix(14).reversed().map(\.function)), default: 0] += 1
            }
            let total = Double(mine.count)
            func percent(_ n: Int) -> Double { (Double(n) / total * 1000).rounded() / 10 }
            func rows(_ counts: [String: (Symbol, Int)]) -> [Report.Row] {
                counts.values.sorted { $0.1 > $1.1 }.prefix(options.limit).map {
                    Report.Row(function: $0.0.function, image: $0.0.image, samples: $0.1, percent: percent($0.1))
                }
            }
            threads.append(Report.ThreadReport(
                name: name, samples: mine.count, busyPercent: percent(busy),
                selfTop: rows(selfCounts), inclusiveTop: rows(inclusive),
                hotStacks: stacks.sorted { $0.value > $1.value }.prefix(min(options.limit, 8)).map {
                    Report.Stack(samples: $0.value, percent: percent($0.value), frames: $0.key)
                }))
        }
        threads.sort { Double($0.samples) * $0.busyPercent > Double($1.samples) * $1.busyPercent }
        let shown = Array(threads.prefix(options.allThreads ? 10 : 1))
        let hidden = threads.count - shown.count
        return Report(seconds: options.seconds, intervalMs: options.intervalMs, samples: samples.count,
                      overheadMs: (overheadMs * 10).rounded() / 10, threads: shown,
                      note: hidden > 0 ? "\(hidden) quieter threads not shown" : nil)
    }

    private static func resolve(_ address: UInt64) -> Symbol {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0 else {
            return Symbol(function: String(format: "0x%llx", address), image: "?")
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let name = info.dli_sname else {
            let offset = address &- UInt64(UInt(bitPattern: info.dli_fbase))
            return Symbol(function: "\(image)+0x\(String(offset, radix: 16))", image: image)
        }
        let raw = String(cString: name)
        // The shared cache hides system libraries' private symbols; the
        // library still says where the time went.
        if raw == "<redacted>" { return Symbol(function: "(private in \(image))", image: image) }
        return Symbol(function: demangle(raw), image: image)
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static let swiftDemangle: Demangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    static func demangle(_ name: String) -> String {
        let mangled = name.hasPrefix("_$s") || name.hasPrefix("$s") || name.hasPrefix("_T")
        guard mangled, let swiftDemangle else { return name }
        let plain = name.hasPrefix("_$s") ? String(name.dropFirst()) : name
        guard let result = plain.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(result) }
        let text = String(cString: result)
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}
