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

- **Unclassified** (no border): Photos that have not yet been classified.
- **Keep** (green border): Photos you want to save.
- **Discard** (red border): Photos you want to delete.

#### How to Classify

**Using the mouse:**
- Click on a photo to cycle through its states:
  - Unclassified → Keep → Discard → Unclassified ...

**Using the keyboard:**
- Use the arrow keys to select a photo.
- Press the Space key to toggle its state.

### 3. Move Discarded Photos

1. Click the "Move Discarded (没)" button in the upper right corner.
2. Photos classified as "Discard" will be moved to a "没" subfolder.
3. Moved photos will be removed from the list.

## Screen Layout

### Left Side: Photo Grid

- Displays photos in a grid format.
- The selected photo is highlighted with a blue border.
- Green border: Kept photos.
- Red border: Discarded photos.

### Upper Right: Preview

- Displays a larger view of the currently selected photo.
- The filename is also shown.

### Lower Right: Discard List

- A list of photos classified as "Discard".
- You can review them before moving.

### Toolbar

- **Open Folder**: Opens a folder.
- **Thumbnail Size Slider**: Changes the display size of photos (100–400px).
- **Clear**: Resets all classifications.
- **Photo Count**: Shows the number of currently loaded photos.
- **Move Discarded**: Moves discarded photos to the "没" folder.

## Keyboard Shortcuts

### Photo Selection

| Key | Action |
|------|------|
| ↑ | Select the photo above |
| ↓ | Select the photo below |
| ← | Select the photo to the left |
| → | Select the photo to the right |

### Photo Actions

| Key | Action |
|------|------|
| Space | Toggle the state of the selected photo (Unclassified→Keep→Discard) |
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

- Horizontal divider position
- Vertical divider position (right panel)
- Thumbnail size (slider position)
- Magnified view window size

Settings are saved automatically when you change them.

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
