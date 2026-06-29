#!/bin/bash
#
# list_minio_immediate_folders.sh
#
# Lists folders under a given MinIO path (using mc) and shows only their
# immediate child folders (one level deep). Does not recurse the tree further.
#
# Structured output with parsed fields:
#   name = provider/model:branch (or model:branch if no provider)
#   provider = top-level folder or "HuggingFace"
#   model = first-level child (or top if no provider)
#   branch = second-level child (often "main" or version like "v0.2")
#   created_at, size, human_size, count_objects from the branch/model level
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
#   ./list_minio_immediate_folders.sh --fast --csv bucket/some/other/prefix > models.csv
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
    echo "name,provider,model,branch,created_at,size,human_size,count_objects"
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

# Process each top-level folder (provider or model) and its children (model/branch)
while IFS= read -r folder; do
    [ -z "$folder" ] && continue

    top_path="${FULL_PATH}/${folder}"

    if [ "$csv_mode" = false ]; then
        echo "📁 ${folder}/"
    fi

    # Get immediate first-level children under this top folder
    children_raw=$(mc ls "${top_path}/" 2>/dev/null | grep '/$' | while read -r line; do
        ts=$(echo "$line" | sed -E 's/^\[([^]]+)\].*/\1/')
        name=$(echo "$line" | awk '{print $NF}')
        echo "${ts}|${name}"
    done | sort -k2 -t'|')

    if [ -z "$children_raw" ]; then
        if [ "$csv_mode" = false ]; then
            echo "   └── (no child folders)"
        fi
    else
        echo "$children_raw" | while IFS='|' read -r child_ts child_name; do
            [ -z "$child_name" ] && continue
            first_child=${child_name%/}
            first_child_path="${top_path}/${first_child}"

            # Check for second-level children (branches) under the first child
            grandchildren_raw=$(mc ls "${first_child_path}/" 2>/dev/null | grep '/$' | while read -r gline; do
                gts=$(echo "$gline" | sed -E 's/^\[([^]]+)\].*/\1/')
                gname=$(echo "$gline" | awk '{print $NF}')
                echo "${gts}|${gname}"
            done | sort -k2 -t'|')

            if [ -n "$grandchildren_raw" ]; then
                # Has grandchildren → top = provider, first_child = model, grandchild = branch
                echo "$grandchildren_raw" | while IFS='|' read -r branch_ts branch_name; do
                    [ -z "$branch_name" ] && continue
                    branch=${branch_name%/}
                    model="${first_child}"
                    provider="${folder}"
                    logical_name="${provider}/${model}:${branch}"
                    target_path="${first_child_path}/${branch}"
                    ts_for_created="$branch_ts"

                    # === Compute created_at, size, count on target_path ===
                    if [ "$fast_mode" = true ]; then
                        created_at="$ts_for_created"
                    else
                        oldest_ts=$(mc ls -r "${target_path}/" 2>/dev/null \
                            | grep -o '\[[^]]*\]' | sed 's/^\[//;s/\]$//' | sort | head -1)
                        if [ -n "$oldest_ts" ]; then
                            created_at="$oldest_ts"
                        else
                            created_at="$ts_for_created"
                        fi
                    fi

                    du_output=$(mc du "${target_path}/" 2>/dev/null | head -1)
                    total_size=$(echo "$du_output" | awk '{print $1, $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    object_count=$(echo "$du_output" | awk '{print $NF}' | sed 's/[^0-9]//g')

                    if [ "$csv_mode" = true ]; then
                        bytes=$(mc du --json "${target_path}/" 2>/dev/null \
                            | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)
                        bytes=${bytes:-0}
                        echo "${logical_name},${provider},${model},${branch},${created_at},${bytes},${total_size:-unknown},${object_count:-0}"
                    else
                        echo "   └── ${logical_name}/"
                        printf "       📅 Created/Modified: %s    📦 Total size: %s (%s objects)\n" \
                               "$created_at" "${total_size:-unknown}" "${object_count:-?}"
                    fi
                done
            else
                # No grandchildren → top = model, first_child = branch, provider = HuggingFace
                branch="${first_child}"
                model="${folder}"
                provider="HuggingFace"
                logical_name="${model}:${branch}"
                target_path="${first_child_path}"
                ts_for_created="$child_ts"

                # === Compute created_at, size, count on target_path ===
                if [ "$fast_mode" = true ]; then
                    created_at="$ts_for_created"
                else
                    oldest_ts=$(mc ls -r "${target_path}/" 2>/dev/null \
                        | grep -o '\[[^]]*\]' | sed 's/^\[//;s/\]$//' | sort | head -1)
                    if [ -n "$oldest_ts" ]; then
                        created_at="$oldest_ts"
                    else
                        created_at="$ts_for_created"
                    fi
                fi

                du_output=$(mc du "${target_path}/" 2>/dev/null | head -1)
                total_size=$(echo "$du_output" | awk '{print $1, $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                object_count=$(echo "$du_output" | awk '{print $NF}' | sed 's/[^0-9]//g')

                if [ "$csv_mode" = true ]; then
                    bytes=$(mc du --json "${target_path}/" 2>/dev/null \
                        | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)
                    bytes=${bytes:-0}
                    echo "${logical_name},${provider},${model},${branch},${created_at},${bytes},${total_size:-unknown},${object_count:-0}"
                else
                    echo "   └── ${logical_name}/"
                    printf "       📅 Created/Modified: %s    📦 Total size: %s (%s objects)\n" \
                           "$created_at" "${total_size:-unknown}" "${object_count:-?}"
                fi
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
    echo "   • Structured output: name (provider/model:branch or model:branch), provider (or HuggingFace), model, branch."
    echo "   • created_at = oldest file timestamp inside the branch/model folder."
    echo "   • Use --csv for the full structured CSV. Add --fast to skip recursive timestamp scans."
fi
