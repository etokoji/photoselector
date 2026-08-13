# photoSelector User Guide

photoSelector is a macOS application for efficiently organizing and classifying large numbers of photos.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Screen Layout](#screen-layout)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [How to Classify Photos](#how-to-classify-photos)
- [RAW File Support](#raw-file-support)
- [Settings Persistence](#settings-persistence)

## Basic Usage

### 1. Open a Folder

1. Click the "Open Folder" button in the upper left corner.
2. Select the folder containing the photos you want to organize.
3. Supported image formats: JPG, PNG, HEIC, GIF, TIFF, and major camera RAW formats (see [RAW File Support](#raw-file-support)).

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
- ⌥ (Option) + ↑/↓ moves the selection in the folder tree; ⌥ (Option) + →/← expands/collapses the selected folder.
- ⌘1 marks the selection Keep, ⌘2 marks it Discard, ⌘0 resets it to Unclassified.
- ⌘A selects all items in the active pane; ⌘D clears the current selection.
- Press Space or Enter to open the magnified preview of the selected photo (press again to close it).

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

### Folder Tree

Right-click a folder in the tree for a context menu:

- **Finderで開く** (Open in Finder): reveals the folder in Finder.
- **新規フォルダ** (New Folder): creates a new subfolder inside it, after prompting for a name.
- **フォルダ名を変更** (Rename Folder): renames the folder. Disabled for the root folder you opened.
- **フォルダを削除** (Delete Folder): moves the folder to the Trash after a confirmation dialog. Disabled for the root folder.

Drag and drop:

- Drag photos — from the grid, or from the Keep/Discard lists — onto a folder in the tree, or onto the photo grid itself, to move them into that folder.
- Hold ⌥ (Option) while dropping to copy instead of move.
- The app copies instead of moves automatically whenever the source or destination is on an external/removable volume.
- Folders themselves (except the root folder) are draggable too, so you can drag a subfolder onto another folder to reorganize your library.
- If an item with the same name already exists at the destination, a dialog offers **両方とも残す** (Keep Both), **置き換える** (Replace), or **中止** (Cancel), with a checkbox to apply the same choice to any remaining conflicts.
- Moves and copies made this way can be undone with ⌘Z (redo with ⇧⌘Z).

### Toolbar & Menu

- **Open Folder**: Opens a folder.
- **Thumbnail Size Slider**: Changes the display size of photos (100–400px).
- **Date Sort**: Choose "File" (default, faster) or "EXIF" (camera timestamp; slower). The preview date label follows this setting.
- **Clear**: Resets all classifications.
- **Photo Count**: Shows the number of currently loaded photos.
- **Move Discarded**: Moves discarded photos (see destination policy above).
- Menu bar "仕分け" (Sorting) provides Keep (⌘1) / Discard (⌘2) / Reset (⌘0), plus "Select All" (⌘A) and "Deselect" (⌘D), all operating on the active pane.

## Keyboard Shortcuts

### Selection & Navigation (active pane)

| Key | Action |
|------|------|
| ↑ / ↓ / ← / → | Move selection within the active pane |
| ⌥ (Option) + ↑ / ↓ | Move the selection up/down in the folder tree |
| ⌥ (Option) + → / ← | Expand / collapse the selected folder |
| ⌘A | Select all items in the active pane |
| ⌘D | Clear the current selection |

### Photo Actions

| Key | Action |
|------|------|
| ⌘1 | Mark the selection as Keep |
| ⌘2 | Mark the selection as Discard |
| ⌘0 | Reset the selection to Unclassified |
| Space / Enter | Open the magnified preview of the selected photo (press again to close it) |

Note: clicking no longer cycles a photo's state — use ⌘1 / ⌘2 / ⌘0, the right-click context menu, or the "仕分け" menu.

### Magnified View Actions

| Key | Action |
|------|------|
| Space / Enter | Close the magnified view |
| ⌘W | Close the magnified view |
| Double-click | Toggle between "fit to window" and 100% (actual pixel) zoom |
| Pinch | Zoom in/out |
| Click-and-drag, or two-finger scroll | Pan the image when zoomed in |

## How to Classify Photos

### Recommended Workflow

1. **Open a Folder**
   - Select the photo folder you want to organize.

2. **Quick Classification**
   - Use the arrow keys to quickly go through photos.
   - Use ⌘1 / ⌘2 (or the right-click menu, or the "仕分け" menu) to instantly mark a photo Keep or Discard.
   - If you're unsure, leave it as unclassified.

3. **Check the Preview**
   - Use the preview panel on the right for a larger view.
   - Press Space or Enter for an even larger (magnified) view.

4. **Final Check**
   - Review the discard list in the lower right.

5. **Execute Move**
   - Click the "Move Discarded (没)" button.

6. **Re-review Unclassified**
   - Go over the remaining unclassified photos.

## RAW File Support

In addition to standard image formats, photoSelector reads major camera RAW formats directly (decoded via macOS's built-in ImageIO RAW support, so no conversion is needed):

- Canon: CR2, CR3
- Nikon: NEF, NRW
- Sony: ARW
- Fujifilm: RAF
- OM System / Olympus: ORF
- Panasonic: RW2
- Pentax: PEF
- Adobe / Leica and others: DNG

RAW files are marked with a small "RAW" badge on their thumbnail so they're easy to tell apart from a JPEG of the same shot at a glance.

If a thumbnail fails to decode (corrupt file, unsupported variant, unreadable media), a warning icon is shown in place of the thumbnail instead of spinning indefinitely.

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

While the app is running, each window remembers its own divider positions and window size as you adjust them. On its own, however, this is **not** carried over the next time you launch the app — every launch starts a fresh window.

To make your current layout persist across launches (and apply to any additional window you open), use the menu bar **Window → "現在の設定とレイアウトをデフォルトにする"** ("Make Current Settings and Layout the Default"). This saves:

- All split view divider positions (main left/right, right panel top/bottom, keep/discard split)
- Thumbnail size (slider position)
- Date sort mode (File / EXIF)
- The sidebar EXIF pane height
- The main window's size

The saved layout is then applied automatically to every new window — including the one that opens the next time you launch the app. Run the command again whenever you want to update the saved default to your current arrangement.

Separately, the Light/Dark appearance mode (set from the menu bar) is always remembered automatically and does not require this step.

The magnified view window's size and position are also saved automatically, independent of the above, and restored the next time you open it.

## Sorting

- Default: File creation date (fast; uses file system metadata only).
- Optional: EXIF Date/Time (slower; reads image metadata and falls back to file date if missing).
- Switch via the toolbar's "Date" segmented control (File / EXIF). The change is applied immediately.

## Tips

### Efficient Classification

1. **Use Keyboard Shortcuts**
   - Classify photos quickly using the arrow keys plus ⌘1 / ⌘2 / ⌘0.

2. **Auto-Scroll**
   - The grid automatically scrolls to keep the selected photo in view.

3. **Adjust Thumbnail Size**
   - Make them larger for detailed checks, smaller to see many photos at once.

4. **Use the Preview**
   - The preview panel always shows the selected photo.
   - Press Space or Enter to toggle the magnified view.

5. **Classify in Stages**
   - First pass: Classify obvious discards.
   - Second pass: Select photos to keep.
   - Third pass: Make a final decision on the rest.

## Troubleshooting

### Photos Not Displaying

- Check if the image format is supported (JPG, PNG, HEIC, GIF, TIFF, or one of the [supported RAW formats](#raw-file-support)).
- Check the folder's read permissions.
- If a thumbnail shows a warning icon instead of the image, the file failed to decode (it may be corrupt or an unsupported RAW variant).

### Keyboard Not Responding

- Click on the photo grid area to focus it.

### Multiple App Instances

- This app is designed to be a single instance.
- Launching it again will activate the existing window.

## System Requirements

- macOS 26.1 or later
- Supported formats: JPG, JPEG, PNG, HEIC, GIF, TIFF, and the RAW formats listed in [RAW File Support](#raw-file-support)

## Privacy and Security

- This app only accesses the folder you select.
- It does not make any network connections.
- Photo data is not sent externally.
- All processing is done locally.

---

The app's "About photoSelector" panel (photoSelector menu) links to the GitHub repository. If you have any questions or issues, please report them in the repository's Issues section: https://github.com/etokoji/photoselector
