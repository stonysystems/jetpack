#!/bin/bash
# patch_canonical_with_reruns.sh - Update canonical TSV files with rerun data.
#
# Reads rerun_results.tsv and replaces the zero-throughput rows in each
# canonical TSV with the successful rerun values.

set -euo pipefail

SWEEP_DIR="docs/sweep_2026-02-28"
RERUN_FILE="${SWEEP_DIR}/rerun_results.tsv"

if [ ! -f "$RERUN_FILE" ]; then
    echo "ERROR: $RERUN_FILE not found" >&2
    exit 1
fi

# Process each rerun result
while IFS=$'\t' read -r dataset conc total h1 h2 h3 h4 h5 fp_att fp_succ fp_rate cpu_avg qd_avg status err_sum log_path retry; do
    [[ "$dataset" =~ ^# ]] && continue
    [[ "$dataset" == "dataset" ]] && continue
    [ "$status" != "OK" ] && continue

    # Find the canonical TSV file
    tsv_file="${SWEEP_DIR}/${dataset}.tsv"
    if [ ! -f "$tsv_file" ]; then
        echo "WARNING: $tsv_file not found, skipping" >&2
        continue
    fi

    # Build the replacement row (old format: 12 columns, no status fields)
    new_row="${conc}\t${total}\t${h1}\t${h2}\t${h3}\t${h4}\t${h5}\t${fp_att}\t${fp_succ}\t${fp_rate}\t${cpu_avg}\t${qd_avg}"

    # Replace the matching row (match on concurrency in first column)
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && echo "$line" >> "$tmpfile" && continue
        row_conc=$(echo "$line" | cut -f1)
        if [ "$row_conc" = "concurrency" ]; then
            echo "$line" >> "$tmpfile"
        elif [ "$row_conc" = "$conc" ]; then
            echo -e "$new_row" >> "$tmpfile"
            echo "  Patched ${dataset} conc=${conc}: 0 -> ${total}" >&2
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$tsv_file"
    mv "$tmpfile" "$tsv_file"
done < "$RERUN_FILE"

echo "Done patching canonical TSVs." >&2
