#!/bin/bash
#
# list_minio_immediate_folders.sh
#
# Lists folders under a given MinIO path (using mc) and shows only their
# immediate child folders (one level deep). Does not recurse the tree further.
#
# For each child folder (e.g. "main/" or model-specific subfolder):
#   - created_at = oldest file timestamp found *inside* it (accurate creation time)
#                  (use --fast to skip recursive scan and use prefix timestamp instead)
#   - size       = total recursive size via mc du
#
# Assumes:
#   - `mc` is installed and in PATH
#   - The bucket/alias is already configured (here: bucket)
#   - Starting path: bucket/folder/
#
# Usage:
#   ./list_minio_immediate_folders.sh
#   ./list_minio_immediate_folders.sh bucket/some/other/prefix
#   ./list_minio_immediate_folders.sh --fast
#   ./list_minio_immediate_folders.sh --csv
#   ./list_minio_immediate_folders.sh --fast --csv bucket/some/other/prefix > output.csv
#
# If no argument is given, it defaults to:
#   bucket/folder/
#
# In --csv mode the output is pure CSV (no colors/messages) so you can redirect to a file.
# --fast skips the recursive mc ls inside each child (much faster on large models).
#

set -euo pipefail

# Check that mc is available
if ! command -v mc >/dev/null 2>&1; then
    echo "❌ Error: 'mc' (MinIO Client) is not installed or not in PATH."
    echo "   Please install it from https://min.io/docs/minio/linux/reference/minio-mc.html"
    exit 1
fi

# === Argument parsing ===
csv_mode=false
fast_mode=false
path_arg=""

for arg in "$@"; do
    if [ "$arg" = "--csv" ]; then
        csv_mode=true
    elif [ "$arg" = "--fast" ]; then
        fast_mode=true
    elif [ -z "$path_arg" ]; then
        path_arg="$arg"
    fi
done

# === Configuration ===
if [ -n "$path_arg" ]; then
    FULL_PATH="$path_arg"
else
    FULL_PATH="bucket/folder"
fi

if [ "$csv_mode" = false ]; then
    echo "🔍 Exploring immediate folder structure under: ${FULL_PATH}/"
    echo "=================================================="
    echo ""

    # Get top-level folders (entries ending with /)
    echo "📥 Fetching top-level folders..."
fi

top_folders=$(mc ls "${FULL_PATH}/" 2>/dev/null \
    | awk '$NF ~ /\/$/ { print $NF }' \
    | sed 's|/$||' \
    | sort)

if [ "$csv_mode" = true ]; then
    echo "model,created_at,size,human_size,count_objects"
fi

if [ -z "$top_folders" ]; then
    if [ "$csv_mode" = false ]; then
        echo "⚠️  No folders found at ${FULL_PATH}/ (or mc command failed)."
    fi
    exit 0
fi

if [ "$csv_mode" = false ]; then
    folder_count=$(echo "$top_folders" | wc -l | tr -d ' ')
    echo "✅ Found ${folder_count} top-level folder(s)."
    echo ""
fi

# Process each top-level folder and list its immediate children only
while IFS= read -r folder; do
    [ -z "$folder" ] && continue

    child_path="${FULL_PATH}/${folder}"

    if [ "$csv_mode" = false ]; then
        echo "📁 ${folder}/"
    fi

    # Get immediate child folders (robust parsing for [timestamp ...] format)
    children_raw=$(mc ls "${child_path}/" 2>/dev/null | grep '/$' | while read -r line; do
        # Extract timestamp inside first [...]
        ts=$(echo "$line" | sed -E 's/^\[([^]]+)\].*/\1/')
        # Extract folder name (last field ending with /)
        name=$(echo "$line" | awk '{print $NF}')
        echo "${ts}|${name}"
    done | sort -k2 -t'|')

    if [ -z "$children_raw" ]; then
        if [ "$csv_mode" = false ]; then
            echo "   └── (no child folders)"
        fi
    else
        echo "$children_raw" | while IFS='|' read -r ts name; do
            [ -z "$name" ] && continue
            name_clean=${name%/}
            full_child="${child_path}/${name_clean}"

            # === Accurate creation time ===
            if [ "$fast_mode" = true ]; then
                # Fast mode: use prefix timestamp (quick)
                created_at="$ts"
            else
                # Full mode: scan recursively inside the child for the oldest file timestamp
                oldest_ts=$(mc ls -r "${full_child}/" 2>/dev/null \
                    | grep -o '\[[^]]*\]' | sed 's/^\[//;s/\]$//' | sort | head -1)

                if [ -n "$oldest_ts" ]; then
                    created_at="$oldest_ts"
                else
                    created_at="$ts"   # fallback
                fi
            fi

            # Get human readable total size + object count from mc du
            du_output=$(mc du "${full_child}/" 2>/dev/null | head -1)
            total_size=$(echo "$du_output" | awk '{print $1, $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            object_count=$(echo "$du_output" | awk '{print $NF}' | sed 's/[^0-9]//g')

            if [ "$csv_mode" = true ]; then
                # CSV row: model,created_at,size (bytes),human_size,count_objects
                model_path="${folder}/${name_clean}"

                # Try to get raw bytes via mc du --json
                bytes=$(mc du --json "${full_child}/" 2>/dev/null \
                    | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)
                bytes=${bytes:-0}

                echo "${model_path},${created_at},${bytes},${total_size:-unknown},${object_count:-0}"
            else
                # Pretty terminal output
                echo "   └── ${name_clean}/"
                printf "       📅 Created/Modified: %s    📦 Total size: %s (%s objects)\n" \
                       "$created_at" "${total_size:-unknown}" "${object_count:-?}"
            fi
        done
    fi

    if [ "$csv_mode" = false ]; then
        echo ""
    fi
done <<< "$top_folders"

if [ "$csv_mode" = false ]; then
    echo "✨ Done."
    if [ "$fast_mode" = true ]; then
        echo "   • Fast mode enabled (created_at = prefix timestamp from mc ls)."
    else
        echo "   • created_at = oldest file timestamp found *inside* the child folder (real creation/upload time)."
    fi
    echo "   • Total size comes from 'mc du' (recursive sum of all objects under the folder)."
    echo "   • Only immediate children shown (e.g. 'main/' or other). Use --csv for spreadsheet-friendly output."
    echo "   • CSV columns: model, created_at, size (bytes), human_size, count_objects"
    echo "   • Add --fast for much quicker runs on large model folders."
fi
