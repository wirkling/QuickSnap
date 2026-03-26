---
name: read-metadata
description: Extract and display image metadata (EXIF/TIFF descriptions) from PNG/JPG files. Use when the user asks to check, inspect, or read metadata from an image.
argument-hint: <image-path>
allowed-tools: [Bash, Read]
---

# Read Image Metadata

Extract embedded metadata from an image file using macOS Spotlight (`mdls`).

## Instructions

1. Take the image path from the user's argument (or ask if not provided)
2. Run the following to extract all relevant metadata:

```bash
mdls -name kMDItemDescription -name kMDItemComment -name kMDItemContentCreationDate -name kMDItemPixelWidth -name kMDItemPixelHeight -name kMDItemDisplayName "$IMAGE_PATH"
```

3. Present the results to the user, highlighting:
   - **Description**: The AI-generated content description (kMDItemDescription)
   - **Dimensions**: Width x Height
   - **Created**: Creation date
   - If no description metadata exists, let the user know the image has no embedded description

This works with any PNG/JPG that has EXIF/TIFF description metadata — including screenshots from QuickSnap.
