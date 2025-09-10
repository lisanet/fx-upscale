import Foundation

extension URL {
    public func renamed(_ transform: (_ currentName: String) -> String) -> URL {
        deletingLastPathComponent()
            .appending(component: transform(deletingPathExtension().lastPathComponent))
            .appendingPathExtension(pathExtension)
    }
}
