#!/bin/bash
#
# list_minio_immediate_folders.sh
#
# Lists folders under a given MinIO path (using mc) and shows only their
# immediate child folders (one level deep). Does not recurse further.
#
# Assumes:
#   - `mc` is installed and in PATH
#   - The bucket/alias is already configured (here: bucket)
#   - Starting path: bucket/parent_folder/
#
# Usage:
#   ./list_minio_immediate_folders.sh
#   ./list_minio_immediate_folders.sh bucket/parent_folder
#   ./list_minio_immediate_folders.sh --csv
#   ./list_minio_immediate_folders.sh --csv bucket/parent_folder > output.csv
#
# If no argument is given, it defaults to:
#   bucket/parent_folder/
#
# In --csv mode the output is pure CSV (no colors/messages) so you can redirect to a file.
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
path_arg=""

for arg in "$@"; do
    if [ "$arg" = "--csv" ]; then
        csv_mode=true
    elif [ -z "$path_arg" ]; then
        path_arg="$arg"
    fi
done

# === Configuration ===
if [ -n "$path_arg" ]; then
    FULL_PATH="$path_arg"
else
    FULL_PATH="bucket/parent_folder"
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
    echo "model,created_at,size,human_size"
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

    # Get immediate child folders + their listed timestamp from mc ls
    # Format per line: DATE TIME SIZE NAME/
    children_raw=$(mc ls "${child_path}/" 2>/dev/null | awk '
        $NF ~ /\/$/ {
            print $1, $2, $3, $NF
        }' | sort -k4)

    if [ -z "$children_raw" ]; then
        if [ "$csv_mode" = false ]; then
            echo "   └── (no child folders)"
        fi
    else
        echo "$children_raw" | while read -r date time size name; do
            [ -z "$name" ] && continue
            name_clean=${name%/}                    # remove trailing slash
            full_child="${child_path}/${name_clean}"

            # Get human readable total size (always)
            total_size=$(mc du "${full_child}/" 2>/dev/null | head -1 | awk '{print $1, $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [ "$csv_mode" = true ]; then
                # CSV row: model,created_at,size (bytes),human_size
                model_path="${folder}/${name_clean}"
                created_at="${date} ${time}"

                # Try to get raw bytes via mc du --json (modern mc versions)
                bytes=$(mc du --json "${full_child}/" 2>/dev/null \
                    | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)
                bytes=${bytes:-0}

                echo "${model_path},${created_at},${bytes},${total_size:-unknown}"
            else
                # Pretty terminal output
                echo "   └── ${name_clean}/"
                printf "       📅 Created/Modified: %s %s    📦 Total size: %s\n" \
                       "$date" "$time" "${total_size:-unknown}"
            fi
        done
    fi

    if [ "$csv_mode" = false ]; then
        echo ""
    fi
done <<< "$top_folders"

if [ "$csv_mode" = false ]; then
    echo "✨ Done."
    echo "   • Timestamp shown is from 'mc ls' (usually last activity on the prefix)."
    echo "   • Total size comes from 'mc du' (recursive sum of all objects under the folder)."
    echo "   • Only immediate children are shown — no deeper recursion."
    echo "   • Use --csv flag for machine-readable CSV output (e.g. ./script.sh --csv > output.csv)"
fi
