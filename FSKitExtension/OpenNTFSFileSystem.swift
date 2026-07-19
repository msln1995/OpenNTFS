import Foundation
import FSKit

@objc
final class OpenNTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        // Until the libntfs bridge is linked, never claim a disk from the system.
        replyHandler(.notRecognized, nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        replyHandler(nil, NSError(
            domain: "cn.openntfs.fskit",
            code: Int(ENOTSUP),
            userInfo: [NSLocalizedDescriptionKey: "The libntfs bridge is not linked yet."]
        ))
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}
}
