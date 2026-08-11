// MARK: - File System Item for Tree View
struct FileSystemItem: Identifiable, Hashable {
    let id: URL
    let name: String
    var children: [FileSystemItem]?
    let isFolder: Bool
}

// MARK: - Photo Item for Grid View

import Foundation
import SwiftUI
import ImageIO

enum PhotoStatus {
    case unknown
    case groupA // Keep
    case groupB // Discard (没)
}

struct PhotoItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let url: URL
    var status: PhotoStatus = .unknown

    // Camera RAW formats decoded by the system ImageIO RAW support.
    // loadPhotos builds its whitelist from this set, so adding a format here
    // both lists the files and gives them the RAW badge.
    static let rawExtensions: Set<String> = [
        "cr2", "cr3",        // Canon
        "nef", "nrw",        // Nikon
        "arw",               // Sony
        "raf",               // Fujifilm
        "orf",               // OM System / Olympus
        "rw2",               // Panasonic
        "pef",               // Pentax
        "dng"                // Adobe / Leica ほか
    ]

    var isRAW: Bool {
        Self.rawExtensions.contains(url.pathExtension.lowercased())
    }

    // Helper to get filename
    var filename: String {
        return url.lastPathComponent
    }

    var formattedFileSize: String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else { return nil }
            return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
        } catch {
            return nil
        }
    }
    
    // Fast: file system creation date
    var fileCreationDate: Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.creationDate] as? Date
        } catch {
            return nil
        }
    }
    
    // Slow: EXIF/TIFF date (if available)
    var exifCreationDate: Date? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateTimeOriginal = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: dateTimeOriginal) {
                return date
            }
        }
        if let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateTime = tiffDict[kCGImagePropertyTIFFDateTime] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: dateTime) {
                return date
            }
        }
        return nil
    }
}
