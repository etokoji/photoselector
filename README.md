# photoSelector User Guide

photoSelector is a macOS application for efficiently organizing and classifying large numbers of photos.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Screen Layout](#screen-layout)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [How to Classify Photos](#how-to-classify-photos)
- [Settings Persistence](#settings-persistence)

## Basic Usage

### 1. Open a Folder

1. Click the "Open Folder" button in the upper left corner.
2. Select the folder containing the photos you want to organize.
3. Supported image formats: JPG, PNG, HEIC, GIF, TIFF.

### 2. Classify Photos

Photos can be classified into three states:

- **Unclassified** (no border)
- **Keep** (green border)
- **Discard** (red border)

#### How to Classify

- Mouse click now performs selection (it no longer cycles the state).
- Right-click opens a context menu with actions: "Mark as Keep", "Mark as Discard", "Reset to Unclassified".
- When right-clicking on an unselected cell, that cell is selected first and then the menu opens.
- Multi-select is supported:
  - ⌘-Click: add/remove a single item to the selection
  - ⇧-Click: select a range in the current pane

**Using the keyboard:**
- Use the arrow keys to move selection (within the currently active pane).
- Press Space to toggle the primary selection's state (Unclassified → Keep → Discard → Unclassified).

### 3. Move Discarded Photos

1. Click the "Move Discarded (没)" button in the upper right corner.
2. Discarded photos are moved to a sibling folder named "<current-folder-name>_没" next to the currently selected folder.
   - If the sibling folder cannot be created due to permissions/sandbox, the app falls back to creating a "没" subfolder inside the current folder.
3. Moved photos are removed from the lists in real time.

## Screen Layout

The main window uses a 3-pane layout:

- Left: Folder tree (select a folder to load photos)
- Center: Photo grid (unified view of the current folder)
- Right: A split panel with Preview (top) and "Keep" / "Discard" lists (bottom, horizontally split)

Additional behavior:
- The currently active pane is lightly highlighted. Keyboard navigation (arrow keys) and Cmd+A operate on the active pane.
- All grids (center, Keep, Discard) auto-scroll to keep the selected item visible.

### Toolbar & Menu

- **Open Folder**: Opens a folder.
- **Thumbnail Size Slider**: Changes the display size of photos (100–400px).
- **Date Sort**: Choose "File" (default, faster) or "EXIF" (camera timestamp; slower). The preview date label follows this setting.
- **Clear**: Resets all classifications.
- **Photo Count**: Shows the number of currently loaded photos.
- **Move Discarded**: Moves discarded photos (see destination policy above).
- Menu bar "仕分け" provides the same Keep / Discard / Reset actions and "Select All" (⌘A) that operate on the active pane.

## Keyboard Shortcuts

### Selection & Navigation (active pane)

| Key | Action |
|------|------|
| ↑ / ↓ / ← / → | Move selection within the active pane |
| ⌘A | Select all items in the active pane |

### Photo Actions

| Key | Action |
|------|------|
| Space | Toggle the primary selection's state (Unclassified→Keep→Discard) |
| Enter | Open the selected photo in a magnified view |

### Magnified View Actions

| Key | Action |
|------|------|
| Enter | Close the magnified view |
| ⌘W | Close the magnified view |
| Double Tap | Reset zoom and position |
| Pinch | Zoom in/out |
| Two-finger drag | Pan the image |

## How to Classify Photos

### Recommended Workflow

1. **Open a Folder**
   - Select the photo folder you want to organize.

2. **Quick Classification**
   - Use the arrow keys to quickly go through photos.
   - Use the Space key to instantly decide to keep or discard.
   - If you're unsure, leave it as unclassified.

3. **Check the Preview**
   - Use the preview panel on the right for a larger view.
   - Press Enter for an even larger view.

4. **Final Check**
   - Review the discard list in the lower right.

5. **Execute Move**
   - Click the "Move Discarded (没)" button.

6. **Re-review Unclassified**
   - Go over the remaining unclassified photos.

## Layout Customization

### Adjusting Dividers

All three dividers in the app can be adjusted by dragging:

1. **Horizontal Divider**
   - Adjusts the width of the photo grid and the preview/discard list.

2. **Vertical Divider (right side)**
   - Adjusts the height of the preview and the discard list.

3. **Thumbnail Size**
   - Use the slider to change the photo size.

### Magnified View Window

- The window can be resized by dragging its corners.
- The image will automatically adjust to the window size.

## Settings Persistence

The following settings are automatically saved and restored on the next launch:

- All split view divider positions (main left/right, right panel top/bottom, keep/discard split)
- Thumbnail size (slider position)
- Magnified view window size

Settings are saved automatically when you change them.

## Sorting

- Default: File creation date (fast; uses file system metadata only).
- Optional: EXIF Date/Time (slower; reads image metadata and falls back to file date if missing).
- Switch via the toolbar's "Date" segmented control (File / EXIF). The change is applied immediately.

## Tips

### Efficient Classification

1. **Use Keyboard Shortcuts**
   - Classify photos quickly using only the arrow keys and the Space key.

2. **Auto-Scroll**
   - The grid automatically scrolls to keep the selected photo in view.

3. **Adjust Thumbnail Size**
   - Make them larger for detailed checks, smaller to see many photos at once.

4. **Use the Preview**
   - The preview panel always shows the selected photo.
   - Press Enter to toggle the magnified view.

5. **Classify in Stages**
   - First pass: Classify obvious discards.
   - Second pass: Select photos to keep.
   - Third pass: Make a final decision on the rest.

## Troubleshooting

### Photos Not Displaying

- Check if the image format is supported (JPG, PNG, HEIC, GIF, TIFF).
- Check the folder's read permissions.

### Keyboard Not Responding

- Click on the photo grid area to focus it.

### Multiple App Instances

- This app is designed to be a single instance.
- Launching it again will activate the existing window.

## System Requirements

- macOS 26.1 or later
- Supported formats: JPG, JPEG, PNG, HEIC, GIF, TIFF

## Privacy and Security

- This app only accesses the folder you select.
- It does not make any network connections.
- Photo data is not sent externally.
- All processing is done locally.

---

If you have any questions or issues, please report them in the GitHub repository's Issues section.
