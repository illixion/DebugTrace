import Foundation

/// Identity and health of the running app, the device and the process —
/// what every trace starts with and what `_info` returns.
public struct DebugAppInfo: Codable, Sendable {
    public struct App: Codable, Sendable {
        public let bundleId: String
        public let name: String
        public let version: String
        /// `CFBundleVersion`. For builds from build-and-sign this is the git
        /// short SHA, with `-dirty` when the tree had local changes.
        public let build: String
        /// The platform this binary was compiled for.
        public let platform: String
        public let configuration: String
        /// Set when the binary runs under compatibility on another platform:
        /// `iOSAppOnVisionOS` is an iPad build on a Vision Pro.
        public let runningAs: String?
    }

    public struct Device: Codable, Sendable {
        public let model: String
        public let os: String
        public let processorCount: Int
        public let physicalMemoryBytes: UInt64
        public let locale: String
        public let timeZone: String
    }

    public struct Process: Codable, Sendable {
        public let pid: Int32
        public let launchedAt: String?
        public let uptimeSeconds: Double?
        public let memoryFootprintBytes: UInt64?
        public let thermalState: String
        public let lowPowerMode: Bool
    }

    public struct Trace: Codable, Sendable {
        public let session: String
        /// The per-build key build-and-sign embeds; nil for Xcode builds.
        public let signingKeyId: String?
        public let uploadConfigured: Bool
        public let subsystems: [String]
    }

    public let app: App
    public let device: Device
    public let process: Process
    public let trace: Trace
    public let capturedAt: String

    public static func current() -> DebugAppInfo {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        let launchedAt = processStartDate()
        let credential = DebugTrace.credential
        return DebugAppInfo(
            app: App(
                bundleId: bundle.bundleIdentifier ?? processInfo.processName,
                name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? processInfo.processName,
                version: (info["CFBundleShortVersionString"] as? String) ?? "",
                build: (info["CFBundleVersion"] as? String) ?? "",
                platform: compiledPlatform,
                configuration: buildConfiguration,
                runningAs: compatibilityMode()),
            device: Device(
                model: deviceModel(),
                os: "\(osName) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                processorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory,
                locale: Locale.current.identifier,
                timeZone: TimeZone.current.identifier),
            process: Process(
                pid: processInfo.processIdentifier,
                launchedAt: launchedAt.map(DebugTime.iso),
                uptimeSeconds: launchedAt.map { (Date().timeIntervalSince($0) * 10).rounded() / 10 },
                memoryFootprintBytes: memoryFootprint(),
                thermalState: thermalStateName(processInfo.thermalState),
                lowPowerMode: processInfo.isLowPowerModeEnabled),
            trace: Trace(
                session: DebugTrace.breadcrumbs.sessionId,
                signingKeyId: credential?.keyId,
                uploadConfigured: credential?.uploadURL != nil,
                subsystems: DebugTrace.configuration.subsystems),
            capturedAt: DebugTime.iso(Date()))
    }

    // MARK: Platform

    static var compiledPlatform: String {
        #if os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }

    private static var osName: String {
        #if os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func compatibilityMode() -> String? {
        #if os(iOS)
        let processInfo = ProcessInfo.processInfo
        if #available(iOS 26.1, *), processInfo.isiOSAppOnVision { return "iOSAppOnVisionOS" }
        // Before 26.1 there is no flag, but the hardware still says what it is.
        if sysctlString("hw.machine")?.hasPrefix("RealityDevice") == true { return "iOSAppOnVisionOS" }
        if processInfo.isiOSAppOnMac { return "iOSAppOnMac" }
        if processInfo.isMacCatalystApp { return "macCatalyst" }
        #endif
        return nil
    }

    private static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        // hw.machine is the model on iOS-family devices ("iPhone16,1") but
        // only the architecture on a Mac, where hw.model has it.
        #if os(macOS)
        return sysctlString("hw.model") ?? "Mac"
        #else
        return sysctlString("hw.machine") ?? "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// `task_vm_info.phys_footprint` — what jetsam counts against this
    /// process. Same read as RAVESystemMonitor's.
    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
