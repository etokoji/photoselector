# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

photoSelector is a macOS SwiftUI application for sorting and organizing photos. Users can load a folder of images, classify them into two groups (keep/discard), and move discarded photos to a "没" (discard) folder.

## Build and Run Commands

### Build the app
```bash
xcodebuild -project photoSelector.xcodeproj -scheme photoSelector -configuration Debug build
```

### Build for Release
```bash
xcodebuild -project photoSelector.xcodeproj -scheme photoSelector -configuration Release build
```

### Run the app (from Xcode)
```bash
open photoSelector.xcodeproj
# Then press Cmd+R in Xcode to build and run
```

### Clean build
```bash
xcodebuild -project photoSelector.xcodeproj -scheme photoSelector clean
```

### Generate app icons
The project includes a Python utility for generating app icons from source images:
```bash
python3 convert_image_to_icons.py
```
Note: Update `INPUT_IMAGE` and `OUTPUT_DIR` paths in the script before running.

## Architecture

### Application Structure
- **SwiftUI-based macOS app** using MVVM pattern
- **Minimum deployment target**: macOS 26.1
- **Swift version**: 5.0
- **Single Instance**: `LSMultipleInstancesProhibited` is set to `true` in the project settings.
- **Settings Persistence**: Uses `UserDefaults` to save and restore:
  - Main horizontal split position
  - Right panel's vertical split position
  - Thumbnail size slider value
  - Preview window size

### Key Components

#### PhotoSorterViewModel (photoSelector/PhotoSorterViewModel.swift)
The central state manager using `ObservableObject`:
- Manages photo collection, loading, and status changes
- Handles keyboard navigation state (`selectedPhotoID`)
- Handles file system operations (loading images, moving files)
- Implements three-state classification: `.unknown` (unclassified), `.groupA` (keep), `.groupB` (discard)
- Creates and manages the "没" folder for discarded items
- Performs async file operations on background queues

#### ContentView (photoSelector/ContentView.swift)
Main UI with three sections:
1. **Toolbar**: Folder selection, thumbnail size slider, photo count, clear button, move button
2. **Grid View**: Adaptive grid of photo thumbnails with status indicators
3. **Side Panel**: A split view with a preview of the selected image on top and a list of discarded photos at the bottom. The divider is resizable.

UI features:
- **Keyboard Navigation**: Arrow keys to select, Space to toggle status, Enter to open a resizable preview window.
- **Native Split Views**: Uses `NSViewRepresentable` wrappers for `NSSplitView` to create resizable horizontal and vertical split views.
- **Dynamic Thumbnail Sizing**: A slider in the toolbar controls the thumbnail size (100-400px).
- **Thumbnail Generation**: `ThumbnailGenerator` class creates and caches thumbnails for efficient display of large images.
- **Visual Status Indicators**: Colored borders and icons indicate the status of each photo.
- **Preview Window**: A separate, resizable window for viewing images with native pinch-to-zoom and pan functionality.

#### PhotoItem (photoSelector/PhotoItem.swift)
Data model for individual photos:
- `Identifiable` and `Hashable` conformance
- Stores file URL and classification status
- Provides filename helper property
- Reads EXIF or file creation date

#### SplitViewControllerRepresentable (photoSelector/SplitViewControllerRepresentable.swift)
`NSViewRepresentable` wrapper for native `NSSplitView`:
- Provides three resizable split views: main horizontal, right-side vertical, and the preview window.
- Uses `NSHostingController` to embed SwiftUI views.
- `ZoomableAsyncImageView`: A custom `NSViewRepresentable` that wraps `NSScrollView` and `NSImageView` to provide native pinch-to-zoom, pan, and double-tap-to-reset functionality.
- `CenteringClipView`: A custom `NSClipView` to ensure the image is always centered in the scroll view.

### File Organization Flow
1. User selects folder via `NSOpenPanel`
2. ViewModel scans for image files (jpg, jpeg, png, heic, gif, tiff)
3. User clicks photos to cycle through: unclassified → keep → discard → unclassified
4. "Move Discarded" creates "没" subfolder and moves all Group B items
5. Moved items are removed from the grid in real-time

### Concurrency Model
- Main actor isolation: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- UI updates dispatched to `DispatchQueue.main`
- File operations and thumbnail generation run on background queues (`DispatchQueue.global`).
- Uses `@Published` properties for reactive UI updates

### Sandbox Permissions
The app has restricted sandbox permissions with only:
- User-selected files: read/write access
- No network, camera, location, or other system resources

## Code Style Notes

- SwiftUI declarative UI patterns throughout
- Observable pattern for state management
- Guard statements for early returns in error conditions
- Conditional compilation for platform-specific code (`#if os(macOS)`)
- Enum-based state modeling (PhotoStatus)
- Japanese text labels ("没" for discard folder)
