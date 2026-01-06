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
    
    // Helper to get filename
    var filename: String {
        return url.lastPathComponent
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
