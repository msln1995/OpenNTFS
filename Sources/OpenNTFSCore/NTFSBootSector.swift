import Foundation

public struct NTFSBootSector: Equatable, Sendable {
    public let bytesPerSector: UInt16
    public let sectorsPerCluster: UInt8
    public let totalSectors: UInt64
    public let mftCluster: UInt64
    public let serialNumber: UInt64

    public var bytesPerCluster: UInt64 {
        UInt64(bytesPerSector) * UInt64(sectorsPerCluster)
    }

    public init?(data: Data) {
        guard data.count >= 512,
              data[3..<11].elementsEqual(Data("NTFS    ".utf8)) else {
            return nil
        }

        let bytesPerSector = data.readLittleEndian(UInt16.self, at: 11)
        let sectorsPerCluster = data[13]
        let totalSectors = data.readLittleEndian(UInt64.self, at: 40)
        let mftCluster = data.readLittleEndian(UInt64.self, at: 48)
        let serialNumber = data.readLittleEndian(UInt64.self, at: 72)

        guard Self.validSectorSize(bytesPerSector),
              sectorsPerCluster > 0,
              sectorsPerCluster.nonzeroBitCount == 1,
              totalSectors > 0,
              mftCluster < totalSectors / UInt64(sectorsPerCluster) else {
            return nil
        }

        self.bytesPerSector = bytesPerSector
        self.sectorsPerCluster = sectorsPerCluster
        self.totalSectors = totalSectors
        self.mftCluster = mftCluster
        self.serialNumber = serialNumber
    }

    private static func validSectorSize(_ value: UInt16) -> Bool {
        value >= 256 && value <= 4096 && value.nonzeroBitCount == 1
    }
}

private extension Data {
    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let width = MemoryLayout<T>.size
        return self[offset..<(offset + width)].enumerated().reduce(0) { result, item in
            result | (T(item.element) << T(item.offset * 8))
        }
    }
}
