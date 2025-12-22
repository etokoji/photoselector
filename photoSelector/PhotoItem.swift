//
//  PhotoItem.swift
//  photoSelector
//
//  Created by Antigravity on 2025/12/01.
//

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
    
    // Get creation date from EXIF or file attributes
    var creationDate: Date? {
        // Try to get EXIF creation date
        if let exifDate = getExifCreationDate() {
            return exifDate
        }
        
        // Fallback to file creation date
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.creationDate] as? Date
        } catch {
            print("Error getting file attributes: \(error)")
            return nil
        }
    }
    
    private func getExifCreationDate() -> Date? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }
        
        // kCGImagePropertyExifDictionary is for EXIF data
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateTimeOriginal = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: dateTimeOriginal) {
                return date
            }
        }
        
        // kCGImagePropertyTIFFDictionary can also contain creation date
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
