#!/bin/bash
# tsv_to_md.sh - Convert sweep TSV files to Markdown tables.
#
# Usage:
#   ./tsv_to_md.sh <tsv_file>           # Convert one file
#   ./tsv_to_md.sh docs/sweep_2026-02-28/*.tsv  # Convert all
#
# For each input foo.tsv, writes foo.md with:
#   - metadata header extracted from TSV comment lines
#   - Markdown table of all rows
#   - notes on failed rows (0 total throughput)

set -euo pipefail

convert_one() {
    local tsv="$1"
    local md="${tsv%.tsv}.md"
    local basename
    basename=$(basename "$tsv" .tsv)

    # Extract metadata from comment lines
    local image mode site_config latency duration date_str
    image=$(grep '^# Sweep:' "$tsv" | sed 's/.*image=\([^ ]*\).*/\1/' || echo "unknown")
    mode=$(grep '^# Sweep:' "$tsv" | sed "s/.*mode=\([^ ]*\).*/\1/" || echo "unknown")
    site_config=$(grep '^# Site config:' "$tsv" | sed 's/^# Site config: //' || echo "unknown")
    latency=$(grep '^# Latency:' "$tsv" | sed 's/^# Latency: //' || echo "unknown")
    date_str=$(grep '^# Date:' "$tsv" | sed 's/^# Date: //' || echo "unknown")
    local git_commit
    git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Read header line (first non-comment line)
    local header_line
    header_line=$(grep -v '^#' "$tsv" | head -1)

    # Determine column count and whether new-format (has status column)
    local ncols
    ncols=$(echo "$header_line" | awk -F'\t' '{print NF}')
    local has_status=false
    if echo "$header_line" | grep -q 'status'; then
        has_status=true
    fi

    # Identify failed rows (total_throughput == 0)
    local failed_rows=""
    local failed_count=0
    while IFS=$'\t' read -r conc total rest; do
        [[ "$conc" =~ ^# ]] && continue
        [[ "$conc" == "concurrency" ]] && continue
        local is_zero
        is_zero=$(echo "$total == 0" | bc 2>/dev/null || echo "0")
        if [ "$is_zero" -eq 1 ]; then
            failed_rows="${failed_rows}  - concurrency=${conc}: 0 throughput"
            if $has_status; then
                local status_val
                status_val=$(echo "$rest" | awk -F'\t' '{print $(NF-3)}')
                local error_val
                error_val=$(echo "$rest" | awk -F'\t' '{print $(NF-2)}')
                if [ -n "$status_val" ] && [ "$status_val" != "0" ]; then
                    failed_rows="${failed_rows} (status=${status_val}"
                    if [ -n "$error_val" ]; then
                        failed_rows="${failed_rows}, ${error_val}"
                    fi
                    failed_rows="${failed_rows})"
                fi
            fi
            failed_rows="${failed_rows}\n"
            failed_count=$((failed_count + 1))
        fi
    done < "$tsv"

    # Build markdown
    {
        echo "# ${basename}"
        echo ""
        echo "| Field | Value |"
        echo "|-------|-------|"
        echo "| Image | \`${image}\` |"
        echo "| Mode | \`${mode}\` |"
        echo "| Site config | ${site_config} |"
        echo "| Latency / Duration | ${latency} |"
        if [ "$date_str" != "unknown" ]; then
            echo "| Date | ${date_str} |"
        fi
        echo "| Git commit | \`${git_commit}\` |"
        echo "| Source | [\`$(basename "$tsv")\`]($(basename "$tsv")) |"
        echo ""

        # Convert TSV data rows to markdown table
        local first=true
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            if $first; then
                # Header row
                local md_header=""
                local md_sep=""
                IFS=$'\t' read -ra cols <<< "$line"
                for col in "${cols[@]}"; do
                    md_header="${md_header}| ${col} "
                    md_sep="${md_sep}| --- "
                done
                echo "${md_header}|"
                echo "${md_sep}|"
                first=false
            else
                # Data row
                local md_row=""
                IFS=$'\t' read -ra cols <<< "$line"
                for col in "${cols[@]}"; do
                    md_row="${md_row}| ${col} "
                done
                echo "${md_row}|"
            fi
        done < "$tsv"

        # Notes on failed rows
        if [ "$failed_count" -gt 0 ]; then
            echo ""
            echo "### Failed/zero-throughput rows (${failed_count})"
            echo ""
            echo -e "$failed_rows"
            if $has_status; then
                echo "See \`log_path\` column for per-run logs."
            else
                echo "These rows were recorded before failure classification was added."
                echo "See [sweep_benchmark.sh](../../scripts/sweep_benchmark.sh) for the updated script with retry and failure tracking."
            fi
        fi
    } > "$md"

    echo "  $md (${failed_count} failed rows)"
}

if [ $# -eq 0 ]; then
    echo "Usage: $0 <tsv_file> [tsv_file ...]"
    exit 1
fi

echo "Converting TSV files to Markdown..."
for f in "$@"; do
    convert_one "$f"
done
echo "Done."
