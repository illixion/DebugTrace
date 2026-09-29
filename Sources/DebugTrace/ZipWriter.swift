import Foundation

/// A minimal zip archive writer: DEFLATE or stored entries, UTF-8 names, no
/// zip64.
///
/// Apple ships no public zip API. `NSFileCoordinator`'s `.forUploading`
/// trick zips a folder, but it is an implementation detail of the Files
/// integration and not something to depend on on tvOS. What a trace needs —
/// a few small files, written once — is about a hundred lines of the format.
///
/// DEFLATE comes from `NSData.compressed(using: .zlib)`, which is raw
/// DEFLATE with no zlib header: exactly what zip method 8 stores.
struct ZipWriter {
    struct Entry {
        let path: String
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let offset: UInt32
    }

    private(set) var output = Data()
    private var entries: [Entry] = []

    mutating func add(path: String, data: Data, modified: Date = Date()) throws {
        guard data.count < Int(UInt32.max), output.count < Int(UInt32.max), entries.count < Int(UInt16.max) else {
            throw DebugError(.tooLarge, "trace archive exceeds the non-zip64 limits")
        }
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if data.count > 64, let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
           deflated.count < data.count {
            method = 8
            payload = deflated
        }
        let (time, date) = Self.dosDateTime(modified)
        let entry = Entry(path: path, crc: crc, compressedSize: UInt32(payload.count),
                          uncompressedSize: UInt32(data.count), method: method,
                          dosTime: time, dosDate: date, offset: UInt32(output.count))

        output.append(le32: 0x0403_4b50)
        output.append(le16: 20)          // version needed: 2.0
        output.append(le16: 1 << 11)     // flags: UTF-8 names
        output.append(le16: method)
        output.append(le16: time)
        output.append(le16: date)
        output.append(le32: crc)
        output.append(le32: entry.compressedSize)
        output.append(le32: entry.uncompressedSize)
        output.append(le16: UInt16(name.count))
        output.append(le16: 0)           // extra field length
        output.append(name)
        output.append(payload)
        entries.append(entry)
    }

    mutating func finish() -> Data {
        let directoryOffset = output.count
        for entry in entries {
            let name = Data(entry.path.utf8)
            output.append(le32: 0x0201_4b50)
            output.append(le16: 0x0314)  // made by: Unix, 2.0 — so permissions below apply
            output.append(le16: 20)
            output.append(le16: 1 << 11)
            output.append(le16: entry.method)
            output.append(le16: entry.dosTime)
            output.append(le16: entry.dosDate)
            output.append(le32: entry.crc)
            output.append(le32: entry.compressedSize)
            output.append(le32: entry.uncompressedSize)
            output.append(le16: UInt16(name.count))
            output.append(le16: 0)       // extra
            output.append(le16: 0)       // comment
            output.append(le16: 0)       // disk number
            output.append(le16: 0)       // internal attributes
            output.append(le32: UInt32(0o100644) << 16) // external: regular file, rw-r--r--
            output.append(le32: entry.offset)
            output.append(name)
        }
        let directorySize = output.count - directoryOffset
        output.append(le32: 0x0605_4b50)
        output.append(le16: 0)
        output.append(le16: 0)
        output.append(le16: UInt16(entries.count))
        output.append(le16: UInt16(entries.count))
        output.append(le32: UInt32(directorySize))
        output.append(le32: UInt32(directoryOffset))
        output.append(le16: 0)
        return output
    }

    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max(1980, components.year ?? 1980)
        let time = UInt16((components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (components.month ?? 1) << 5 | (components.day ?? 1))
        return (time, day)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
