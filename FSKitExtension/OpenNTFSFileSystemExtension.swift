import ExtensionFoundation
import FSKit

@main
struct OpenNTFSFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        OpenNTFSFileSystem()
    }
}
