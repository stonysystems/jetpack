#!/bin/bash
#
# Run the evaluation notebook programmatically and save an executed copy
# under the result root.
#
# Usage:
#   bash scripts/run_evaluation.sh <result_dir>
#
# Example:
#   bash scripts/run_evaluation.sh results/2026-03-23-10:26:07-zoo-5machines
#
# Prerequisites:
#   pip install jupyter nbconvert matplotlib numpy
#
# This script:
# 1. Derives fixed concurrencies from experiment 0 (if not already done)
# 2. Runs the sanity check on experiment 0 results
# 3. Runs the evaluation notebook with ZOO_EXPTIME set to the result dir
# 4. Saves the executed notebook as <result_dir>/evaluation_executed.ipynb
# 5. Exports figures to <result_dir>/figs/ and tables to <result_dir>/tables/
# 6. Generates SUMMARY.md in the result folder
# 7. Generates EXPERIMENT_REPORT.md with per-protocol analysis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <result_dir>"
    echo "  result_dir: path to the Zoo result directory (relative or absolute)"
    exit 1
fi

RESULT_DIR="$1"

# Resolve to absolute path
if [[ "$RESULT_DIR" != /* ]]; then
    RESULT_DIR="$REPO_ROOT/$RESULT_DIR"
fi

if [ ! -d "$RESULT_DIR" ]; then
    echo "Error: $RESULT_DIR is not a directory"
    exit 1
fi

# Extract the exptime (directory name under results/)
EXPTIME=$(basename "$RESULT_DIR")
echo "=== Evaluation Pipeline ==="
echo "Result dir: $RESULT_DIR"
echo "Exptime:    $EXPTIME"

# Step 1: Derive fixed concurrencies if not already done
FIXED_CONC="$REPO_ROOT/results/fixed_conc.json"
if [ ! -f "$FIXED_CONC" ]; then
    echo ""
    echo "--- Step 1: Deriving fixed concurrencies ---"
    python3 "$SCRIPT_DIR/derive_fixed_conc.py" "$RESULT_DIR"
else
    echo ""
    echo "--- Step 1: fixed_conc.json already exists ---"
    cat "$FIXED_CONC"
fi

# Step 2: Run sanity checks
echo ""
echo "--- Step 2: Running sanity checks ---"
python3 "$SCRIPT_DIR/sanity_check.py" "$RESULT_DIR" || {
    echo "WARNING: Sanity check reported failures (see sanity_checks.md for details)"
}

# Step 3: Run the evaluation notebook
echo ""
echo "--- Step 3: Running evaluation notebook ---"
mkdir -p "$RESULT_DIR/figs" "$RESULT_DIR/tables"

# Create output notebook path
OUTPUT_NB="$RESULT_DIR/evaluation_executed.ipynb"

# Run with jupyter nbconvert --execute
cd "$SCRIPT_DIR"
export ZOO_EXPTIME="$EXPTIME"

if command -v jupyter &> /dev/null; then
    jupyter nbconvert --to notebook --execute \
        --ExecutePreprocessor.timeout=600 \
        --ExecutePreprocessor.kernel_name=python3 \
        --output "$OUTPUT_NB" \
        evaluation.ipynb 2>&1

    echo "Executed notebook saved to: $OUTPUT_NB"
else
    echo "WARNING: jupyter not found. Trying papermill..."
    if command -v papermill &> /dev/null; then
        papermill evaluation.ipynb "$OUTPUT_NB" \
            -p exptime "$EXPTIME" 2>&1
        echo "Executed notebook saved to: $OUTPUT_NB"
    else
        echo "ERROR: Neither jupyter nor papermill found."
        echo "Install with: pip install jupyter nbconvert"
        echo "Or: pip install papermill"
        exit 1
    fi
fi

# Step 4: Generate SUMMARY.md
echo ""
echo "--- Step 4: Generating SUMMARY.md ---"
python3 "$SCRIPT_DIR/generate_summary.py" "$RESULT_DIR"

# Step 5: Generate EXPERIMENT_REPORT.md
echo ""
echo "--- Step 5: Generating EXPERIMENT_REPORT.md ---"
python3 "$SCRIPT_DIR/generate_experiment_report.py" "$RESULT_DIR"

# Step 6: Final summary
echo ""
echo "--- Results ---"
echo "Executed notebook: $OUTPUT_NB"
echo "Figures:           $RESULT_DIR/figs/"
echo "Tables:            $RESULT_DIR/tables/"
echo "Sanity checks:     $RESULT_DIR/sanity_checks.md"
echo "Summary:           $RESULT_DIR/SUMMARY.md"
echo "Experiment report: $RESULT_DIR/EXPERIMENT_REPORT.md"

fig_count=$(ls "$RESULT_DIR/figs/"*.pdf 2>/dev/null | wc -l)
table_count=$(ls "$RESULT_DIR/tables/"* 2>/dev/null | wc -l)
echo "PDF count:         $fig_count"
echo "Table count:       $table_count"

echo ""
echo "=== Done ==="
