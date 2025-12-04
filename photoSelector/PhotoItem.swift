//
//  PhotoItem.swift
//  photoSelector
//
//  Created by Antigravity on 2025/12/01.
//

import Foundation
import SwiftUI

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
}
