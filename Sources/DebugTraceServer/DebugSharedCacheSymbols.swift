import Darwin
import Foundation

/// Names for the system-library functions `dladdr` reports as `<redacted>`.
///
/// The dyld shared cache strips its libraries' local symbols, but the OS keeps
/// them beside it in `dyld_shared_cache_<arch>.symbols`, and an app may read
/// that file (verified on visionOS 27.2: 1.2 GB, 4,454 libraries, 15.9 M
/// symbols). It is mapped, not read: only the pages a lookup touches come in,
/// and they are clean file pages, so they don't count toward the footprint.
///
/// Layout, from dyld's `dyld_cache_format.h`: the file starts with a
/// `dyld_cache_header` whose `localSymbolsOffset` (offset 72) points at a
/// `dyld_cache_local_symbols_info` (nlist, string and entry tables); each entry
/// names a library by its offset from the cache's base and the range of its
/// `nlist_64`s, whose values are unslid addresses.
final class DebugSharedCacheSymbols: @unchecked Sendable {
    nonisolated(unsafe) private static var loaded: DebugSharedCacheSymbols??
    private static let lock = NSLock()

    /// Nil when this OS has no readable symbols file, or its layout isn't one
    /// this understands; callers then keep "(private in <library>)".
    static var shared: DebugSharedCacheSymbols? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let made = DebugSharedCacheSymbols()
        loaded = .some(made)
        return made
    }

    private let cacheStart: UInt
    private let slide: UInt64
    private let info: UnsafeRawPointer
    private let nlistOffset: Int
    private let stringsOffset: Int
    private let stringsSize: Int
    private let entries: [UInt64: (start: Int, count: Int)]
    /// Per library: its function symbols' unslid addresses, sorted, with the
    /// string offset of each name. Built the first time the library is asked about.
    private var tables: [UInt64: [(address: UInt64, name: UInt32)]] = [:]
    private let tablesLock = NSLock()

    private init?() {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        typealias RangeFn = @convention(c) (UnsafeMutablePointer<Int>) -> UnsafeRawPointer?
        typealias PathFn = @convention(c) () -> UnsafePointer<CChar>?
        var size = 0
        guard let rangeSymbol = dlsym(rtldDefault, "_dyld_get_shared_cache_range"),
              let start = unsafeBitCast(rangeSymbol, to: RangeFn.self)(&size),
              let pathSymbol = dlsym(rtldDefault, "dyld_shared_cache_file_path"),
              let path = unsafeBitCast(pathSymbol, to: PathFn.self)() else { return nil }
        // The mapped cache's own header: its first mapping's address is the
        // cache's unslid base.
        let mappingOffset = Int(start.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        guard mappingOffset >= 0x98, mappingOffset < 0x1000 else { return nil }
        let unslidBase = start.loadUnaligned(fromByteOffset: mappingOffset, as: UInt64.self)
        cacheStart = UInt(bitPattern: start)
        slide = UInt64(cacheStart) &- unslidBase

        let fd = open(String(cString: path) + ".symbols", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size > 4096,
              let map = mmap(nil, Int(status.st_size), PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else { return nil }
        let file = UnsafeRawPointer(map)
        let fileSize = Int(status.st_size)
        guard memcmp(file, "dyld_v1", 7) == 0 else { munmap(map, fileSize); return nil }
        let localOffset = Int(file.loadUnaligned(fromByteOffset: 72, as: UInt64.self))
        guard localOffset > 0, localOffset + 24 < fileSize else { munmap(map, fileSize); return nil }
        let info = file + localOffset
        func u32(_ offset: Int) -> Int { Int(info.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        nlistOffset = u32(0)
        stringsOffset = u32(8)
        stringsSize = u32(12)
        let entriesOffset = u32(16), entriesCount = u32(20)
        let nlistCount = u32(4)

        // 64-bit entries (u64 offset, u32 start, u32 count) on current caches,
        // 32-bit (u32 each) on older ones: take the stride whose ranges chain.
        func read(stride: Int) -> [UInt64: (start: Int, count: Int)]? {
            var table: [UInt64: (start: Int, count: Int)] = [:]
            var expected = -1
            for index in 0..<entriesCount {
                let entry = info + entriesOffset + index * stride
                let offset = stride == 16 ? entry.loadUnaligned(as: UInt64.self)
                                          : UInt64(entry.loadUnaligned(as: UInt32.self))
                let first = Int(entry.loadUnaligned(fromByteOffset: stride - 8, as: UInt32.self))
                let count = Int(entry.loadUnaligned(fromByteOffset: stride - 4, as: UInt32.self))
                guard first + count <= nlistCount, expected < 0 || index > 4 || first == expected else { return nil }
                expected = first + count
                table[offset] = (first, count)
            }
            return table
        }
        guard entriesCount > 0, localOffset + entriesOffset + entriesCount * 16 <= fileSize,
              let table = read(stride: 16) ?? read(stride: 12) else { munmap(map, fileSize); return nil }
        entries = table
        self.info = info
    }

    /// The function containing `address`, in the shared-cache library whose
    /// mach header is at `imageBase`.
    func name(for address: UInt, imageBase: UInt) -> String? {
        let key = UInt64(imageBase &- cacheStart)
        guard let symbols = table(for: key), !symbols.isEmpty else { return nil }
        let unslid = UInt64(address) &- slide
        var low = 0, high = symbols.count
        while low < high {
            let mid = (low + high) / 2
            if symbols[mid].address <= unslid { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let strx = Int(symbols[low - 1].name)
        guard strx < stringsSize else { return nil }
        let name = String(cString: (info + stringsOffset + strx).assumingMemoryBound(to: CChar.self))
        // nlist names carry the C linker's leading underscore, which dladdr
        // drops; drop it too so both spell a function the same way.
        return name.hasPrefix("_") ? String(name.dropFirst()) : name
    }

    private func table(for key: UInt64) -> [(address: UInt64, name: UInt32)]? {
        tablesLock.lock()
        defer { tablesLock.unlock() }
        if let known = tables[key] { return known }
        guard let entry = entries[key] else { return nil }
        var symbols: [(address: UInt64, name: UInt32)] = []
        symbols.reserveCapacity(entry.count)
        for index in entry.start..<(entry.start + entry.count) {
            let nlist = info + nlistOffset + index * 16
            let type = nlist.load(fromByteOffset: 4, as: UInt8.self)
            // Defined in a section, not a debugger stab.
            guard type & 0xE0 == 0, type & 0x0E == 0x0E else { continue }
            symbols.append((nlist.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                            nlist.loadUnaligned(as: UInt32.self)))
        }
        symbols.sort { $0.address < $1.address }
        tables[key] = symbols
        return symbols
    }
}
