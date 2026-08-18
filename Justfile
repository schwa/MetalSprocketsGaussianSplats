list:
    @just --list

# Generate DocC documentation for the library targets into ./docs
generate-docs:
    swift package --allow-writing-to-directory ./docs generate-documentation --target Splats --output-path ./docs/Splats
    swift package --allow-writing-to-directory ./docs generate-documentation --target MetalSprocketsGaussianSplats --output-path ./docs/MetalSprocketsGaussianSplats

# Preview DocC documentation locally
preview-docs target="MetalSprocketsGaussianSplats":
    swift package --disable-sandbox preview-documentation --target {{target}}

ack_dir := "Examples/MetalGaussianSplatsDemo/MetalGaussianSplatsDemo/Acknowledgements"

# Gather all LICENSE files from dependencies and copy to Acknowledgements folder
acknowledgements:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ack_dir}}"
    for license in .build/checkouts/*/LICENSE*; do
        if [ -f "$license" ]; then
            pkg=$(echo "$license" | cut -d'/' -f3)
            ext="${license##*/}"
            cp "$license" "{{ack_dir}}/${pkg}-${ext}"
            echo "Copied: $pkg"
        fi
    done
    echo "Done. Licenses copied to {{ack_dir}}"

# Run the renderer benchmark: print device info, then render the CSV as a markdown table
benchmark:
    #!/usr/bin/env bash
    set -euo pipefail
    device=$(system_profiler SPHardwareDataType | awk -F': ' '/Model Name|Chip|Memory/ {a = a (a ? " | " : "") $2} END {print a}')
    echo "Device: $device"
    echo "Date:   $(date '+%Y-%m-%d %H:%M')"
    echo
    swift run --configuration release metalsprockets-gaussian-splat bench 2>/dev/null | duckdb -markdown -c "SELECT * FROM read_csv_auto('/dev/stdin')"

# Detailed per-pass timings for the GPU-sort spark renderer across sizes (JSON on stdout, device on stderr)
sort-perf counts="100000,500000,1000000,4000000,8000000" iterations="120":
    #!/usr/bin/env bash
    set -euo pipefail
    device=$(system_profiler SPHardwareDataType | awk -F': ' '/Model Name|Chip|Memory/ {a = a (a ? " | " : "") $2} END {print a}')
    echo "Device: $device" >&2
    echo "Date:   $(date '+%Y-%m-%d %H:%M')" >&2
    swift run --configuration release metalsprockets-gaussian-splat bench --sort-detail --counts {{counts}} --iterations {{iterations}} 2>/dev/null
