import Foundation
import Darwin
#if canImport(Metal)
import Metal
#endif

/// What `_memory` reports: the numbers an agent needs to tell a leak from a
/// spike from a jetsam about to happen, without a debugger. Every value is a
/// size or a count (no names, no content), so the query is `releaseSafe`.
struct DebugMemoryReport: Encodable {
    struct Process: Encodable {
        /// What jetsam counts against the app (`phys_footprint`).
        let footprintBytes: UInt64
        /// The most the footprint has been this launch.
        let peakFootprintBytes: UInt64?
        let residentBytes: UInt64
        let compressedBytes: UInt64?
        /// How much more the app may allocate before the system kills it
        /// (`os_proc_available_memory`). Nil on macOS, which has no such limit.
        let availableBytes: UInt64?
    }

    struct Malloc: Encodable {
        let blocksInUse: Int
        let sizeInUseBytes: Int
        let sizeAllocatedBytes: Int
    }

    struct Gpu: Encodable {
        let currentAllocatedBytes: Int
        let recommendedMaxWorkingSetBytes: UInt64?
    }

    struct Region: Encodable {
        /// The system's label for what the region is for (`malloc`, `iosurface`,
        /// `ioaccelerator`, `swift metadata`, `stack`), or `tag N`.
        let kind: String
        let regions: Int
        let virtualBytes: UInt64
        let residentBytes: UInt64
        let dirtyBytes: UInt64
        let swappedBytes: UInt64
    }

    let process: Process
    let malloc: Malloc
    let gpu: Gpu?
    /// The largest kinds of mapped memory by dirty + swapped size. Dirty memory
    /// is what counts toward the footprint; clean file-backed pages don't.
    let largestRegionKinds: [Region]
    let regionKindCount: Int
    let sampledInMs: Double

    @MainActor
    static func capture(topRegions: Int) -> DebugMemoryReport {
        let start = ContinuousClock.now
        let regions = Self.regionKinds()
        let elapsed = ContinuousClock.now - start
        return DebugMemoryReport(
            process: process(), malloc: malloc(), gpu: gpu(),
            largestRegionKinds: Array(regions.prefix(topRegions)), regionKindCount: regions.count,
            sampledInMs: DebugSurface.milliseconds(elapsed))
    }

    private static func process() -> Process {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let ok = status == KERN_SUCCESS
        var available: UInt64?
        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
        available = UInt64(os_proc_available_memory())
        #endif
        return Process(
            footprintBytes: ok ? vm.phys_footprint : 0,
            peakFootprintBytes: ok ? UInt64(vm.ledger_phys_footprint_peak) : nil,
            residentBytes: ok ? UInt64(vm.resident_size) : 0,
            compressedBytes: ok ? UInt64(vm.compressed) : nil,
            availableBytes: available)
    }

    private static func malloc() -> Malloc {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Malloc(blocksInUse: Int(stats.blocks_in_use), sizeInUseBytes: Int(stats.size_in_use),
                      sizeAllocatedBytes: Int(stats.size_allocated))
    }

    private static func gpu() -> Gpu? {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        #if os(macOS)
        let working: UInt64? = device.recommendedMaxWorkingSetSize
        #else
        let working: UInt64? = device.recommendedMaxWorkingSetSize
        #endif
        return Gpu(currentAllocatedBytes: device.currentAllocatedSize, recommendedMaxWorkingSetBytes: working)
        #else
        return nil
        #endif
    }

    /// Walks the address space once, summing each kind of region. Thousands of
    /// regions take a few milliseconds.
    private static func regionKinds() -> [Region] {
        struct Sum { var count = 0; var virtual: UInt64 = 0; var resident: UInt64 = 0; var dirty: UInt64 = 0; var swapped: UInt64 = 0 }
        var sums: [UInt32: Sum] = [:]
        var address: vm_address_t = 0
        let page = UInt64(getpagesize())
        while true {
            var size: vm_size_t = 0
            var info = vm_region_extended_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_extended_info_data_t>.size / MemoryLayout<integer_t>.size)
            var object: mach_port_t = 0
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    vm_region_64(mach_task_self_, &address, &size, VM_REGION_EXTENDED_INFO, $0, &count, &object)
                }
            }
            guard status == KERN_SUCCESS else { break }
            var sum = sums[info.user_tag, default: Sum()]
            sum.count += 1
            sum.virtual += UInt64(size)
            sum.resident += UInt64(info.pages_resident) * page
            sum.dirty += UInt64(info.pages_dirtied) * page
            sum.swapped += UInt64(info.pages_swapped_out) * page
            sums[info.user_tag] = sum
            address += size
        }
        return sums
            .map { tag, sum in
                Region(kind: tagNames[tag] ?? "tag \(tag)", regions: sum.count, virtualBytes: sum.virtual,
                       residentBytes: sum.resident, dirtyBytes: sum.dirty, swappedBytes: sum.swapped)
            }
            .sorted { ($0.dirtyBytes + $0.swappedBytes, $0.residentBytes) > ($1.dirtyBytes + $1.swappedBytes, $1.residentBytes) }
    }

    /// `VM_MEMORY_*` from <mach/vm_statistics.h>, for the kinds that matter when
    /// chasing a footprint.
    private static let tagNames: [UInt32: String] = [
        UInt32(VM_MEMORY_MALLOC): "malloc", UInt32(VM_MEMORY_MALLOC_SMALL): "malloc small",
        UInt32(VM_MEMORY_MALLOC_LARGE): "malloc large", UInt32(VM_MEMORY_MALLOC_TINY): "malloc tiny",
        UInt32(VM_MEMORY_MALLOC_NANO): "malloc nano", UInt32(VM_MEMORY_MALLOC_MEDIUM): "malloc medium",
        UInt32(VM_MEMORY_MALLOC_HUGE): "malloc huge", UInt32(VM_MEMORY_STACK): "stack",
        UInt32(VM_MEMORY_GUARD): "guard", UInt32(VM_MEMORY_IOKIT): "iokit",
        UInt32(VM_MEMORY_FOUNDATION): "foundation", UInt32(VM_MEMORY_COREGRAPHICS): "coregraphics",
        UInt32(VM_MEMORY_CGIMAGE): "cgimage", UInt32(VM_MEMORY_IMAGEIO): "imageio",
        UInt32(VM_MEMORY_COREIMAGE): "coreimage", UInt32(VM_MEMORY_LAYERKIT): "layerkit",
        UInt32(VM_MEMORY_SQLITE): "sqlite", UInt32(VM_MEMORY_JAVASCRIPT_CORE): "javascriptcore",
        UInt32(VM_MEMORY_JAVASCRIPT_JIT_EXECUTABLE_ALLOCATOR): "jit code",
        UInt32(VM_MEMORY_DYLIB): "dylib", UInt32(VM_MEMORY_DYLD): "dyld",
        UInt32(VM_MEMORY_SWIFT_RUNTIME): "swift runtime", UInt32(VM_MEMORY_SWIFT_METADATA): "swift metadata",
        UInt32(VM_MEMORY_IOSURFACE): "iosurface", UInt32(VM_MEMORY_IOACCELERATOR): "ioaccelerator",
        UInt32(VM_MEMORY_AUDIO): "audio", UInt32(VM_MEMORY_VIDEOBITSTREAM): "video bitstream",
        UInt32(VM_MEMORY_COREUI): "coreui", UInt32(VM_MEMORY_LIBDISPATCH): "libdispatch",
        UInt32(VM_MEMORY_OS_ALLOC_ONCE): "os alloc once", UInt32(VM_MEMORY_SKYWALK): "skywalk",
        0: "untagged", UInt32(VM_MEMORY_UNSHARED_PMAP): "unshared pmap", UInt32(VM_MEMORY_SHARED_PMAP): "shared pmap",
        UInt32(VM_MEMORY_ANALYSIS_TOOL): "analysis tool", UInt32(VM_MEMORY_SCENEKIT): "scenekit",
    ]
}
