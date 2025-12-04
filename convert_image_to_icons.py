#!/usr/bin/env python3
"""
Convert Gemini-generated image to macOS app icons.
Automatically crops out whitespace and extracts the square content region,
then resizes to all required icon sizes.
"""

import os
from PIL import Image
import numpy as np

INPUT_IMAGE = "/Users/etokoji/Downloads/Gemini_Generated_Image_fwi0qsfwi0qsfwi0.png"
OUTPUT_DIR = "/Users/etokoji/Documents/swift-app/photoSelector/photoSelector/Assets.xcassets/AppIcon.appiconset"

# macOS icon sizes: (size_1x, filename)
ICON_SIZES = [
    (16, "AppIcon-16x16.png"),
    (32, "AppIcon-32x32.png"),
    (64, "AppIcon-64x64.png"),
    (128, "AppIcon-128x128.png"),
    (256, "AppIcon-256x256.png"),
    (512, "AppIcon-512x512.png"),
    (1024, "AppIcon-1024x1024.png"),
]

# How much to additionally scale up the cropped content when fitting into icons (1.0 = no extra upscale)
SCALE_UP = 1.15
# Fraction of the smaller image dimension to use as central crop (0-1)
# e.g. 0.7 means take a square whose side = 70% of the smaller image side, centered
CENTER_FRACTION = 0.5

def analyze_background_color(img, margin_percent=5):
    """
    Analyze the background color at the edges of the image.
    Returns the average color from the margins (assumed to be background).
    """
    img_array = np.array(img, dtype=np.float32)
    h, w = img_array.shape[:2]
    
    margin = int(min(h, w) * margin_percent / 100)
    
    # Sample pixels from all four edges (reshape to 1D for averaging)
    top_edge = img_array[0:margin, :, :].reshape(-1, 3)
    bottom_edge = img_array[-margin:, :, :].reshape(-1, 3)
    left_edge = img_array[:, 0:margin, :].reshape(-1, 3)
    right_edge = img_array[:, -margin:, :].reshape(-1, 3)
    
    # Combine all edge samples
    all_edges = np.vstack([top_edge, bottom_edge, left_edge, right_edge])
    background_color = np.mean(all_edges, axis=0)
    
    return background_color

def find_content_bbox(img, margin_percent=5, tolerance=20):
    """
    Find the bounding box of non-background content.
    
    1. Samples background color from image edges
    2. Finds content that differs from that background (within tolerance)
    
    Args:
        margin_percent: Percentage of image size to sample from edges for background color
        tolerance: Color difference threshold (0-255 per channel)
    """
    img_array = np.array(img, dtype=np.float32)
    
    # Get the background color from edges
    background_color = analyze_background_color(img, margin_percent)
    print(f"  Background color detected: RGB{tuple(background_color.astype(int))}")
    
    r, g, b = img_array[:,:,0], img_array[:,:,1], img_array[:,:,2]
    bg_r, bg_g, bg_b = background_color
    
    # Find pixels that differ from background by more than tolerance
    color_diff = np.sqrt(
        (r - bg_r)**2 + (g - bg_g)**2 + (b - bg_b)**2
    )
    
    # Content is where color difference exceeds tolerance
    is_content = color_diff > tolerance
    
    if not np.any(is_content):
        print("  Warning: No content detected, using full image")
        return (0, 0, img.width, img.height)
    
    # Find bounding box of content
    rows = np.any(is_content, axis=1)
    cols = np.any(is_content, axis=0)
    
    row_indices = np.where(rows)[0]
    col_indices = np.where(cols)[0]
    
    if len(row_indices) == 0 or len(col_indices) == 0:
        return (0, 0, img.width, img.height)
    
    top = row_indices[0]
    bottom = row_indices[-1] + 1
    left = col_indices[0]
    right = col_indices[-1] + 1
    
    return (left, top, right, bottom)

def create_icon_from_cropped(cropped, bg_color, icon_size, scale_up=SCALE_UP):
    """Create a single icon image of `icon_size` from the cropped content.

    The cropped content will be scaled to fit the icon while preserving aspect ratio.
    The scaling uses `scale_up` to optionally make content a bit larger than strict fit.
    """
    width, height = cropped.size
    max_dim = max(width, height)
    # Determine scale so that the larger dimension maps to icon_size * scale_up
    scale = (icon_size * scale_up) / max_dim
    # But do not scale down below 1/ max_dim? allow smaller images to scale up
    new_w = max(1, int(round(width * scale)))
    new_h = max(1, int(round(height * scale)))

    resized = cropped.resize((new_w, new_h), Image.Resampling.LANCZOS)

    # Create background filled icon and paste centered
    bg_tuple = tuple(int(c) for c in bg_color)
    icon = Image.new('RGB', (icon_size, icon_size), bg_tuple)
    x_offset = (icon_size - new_w) // 2
    y_offset = (icon_size - new_h) // 2
    icon.paste(resized, (x_offset, y_offset))
    return icon

def create_icons_from_source():
    """Load source image, extract square content, and create resized versions."""
    
    # Open the source image
    if not os.path.exists(INPUT_IMAGE):
        print(f"Error: Source image not found at {INPUT_IMAGE}")
        return False
    
    try:
        source_img = Image.open(INPUT_IMAGE).convert('RGB')
        print(f"✓ Loaded source image: {source_img.size}")
    except Exception as e:
        print(f"Error loading image: {e}")
        return False
    
    # Extract center crop from the original image (user requested central part enlarged)
    try:
        w, h = source_img.size
        side = int(min(w, h) * CENTER_FRACTION)
        cx, cy = w // 2, h // 2
        left = max(0, cx - side // 2)
        top = max(0, cy - side // 2)
        right = min(w, left + side)
        bottom = min(h, top + side)
        cropped = source_img.crop((left, top, right, bottom))
        print(f"✓ Center-cropped area: {(left, top, right, bottom)}, size: {cropped.size}")
        bg_color = analyze_background_color(source_img)
    except Exception as e:
        print(f"Error extracting center crop: {e}")
        return False
    
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    # Create resized icons for each size from cropped content
    for size, filename in ICON_SIZES:
        try:
            icon_img = create_icon_from_cropped(cropped, bg_color, size)
            output_path = os.path.join(OUTPUT_DIR, filename)
            icon_img.save(output_path, 'PNG', quality=95)
            print(f"✓ Created {filename} ({size}x{size})")
        except Exception as e:
            print(f"✗ Error creating {filename}: {e}")
            return False
    
    return True

if __name__ == "__main__":
    if create_icons_from_source():
        print("\n✓ Icon conversion complete!")
    else:
        print("\n✗ Icon conversion failed!")
