#!/bin/bash
# Claude Code PreToolUse hook: extracts embedded metadata from images
# when the Read tool targets a PNG/JPG file.
# Uses macOS-native mdls to read EXIF/TIFF/Spotlight metadata.

# Read the hook input from stdin
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)

# Only process image files
if ! [[ "$FILE_PATH" =~ \.(png|jpg|jpeg|PNG|JPG|JPEG)$ ]]; then
  exit 0
fi

# Check file exists
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# Extract description via mdls (reads EXIF/TIFF metadata written by CGImageDestination)
DESCRIPTION=$(mdls -name kMDItemDescription -raw "$FILE_PATH" 2>/dev/null)

# mdls returns "(null)" when no metadata exists
if [ -z "$DESCRIPTION" ] || [ "$DESCRIPTION" = "(null)" ]; then
  # Try comment field as fallback
  DESCRIPTION=$(mdls -name kMDItemComment -raw "$FILE_PATH" 2>/dev/null)
fi

if [ -z "$DESCRIPTION" ] || [ "$DESCRIPTION" = "(null)" ]; then
  exit 0
fi

# Inject metadata as additional context
/usr/bin/python3 -c "
import json, sys
desc = sys.stdin.read().strip()
output = {
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'allow',
        'additionalContext': 'Image Metadata (AI-generated description of image content):\n' + desc
    }
}
print(json.dumps(output))
" <<< "$DESCRIPTION"
