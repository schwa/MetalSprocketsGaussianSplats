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

benchmark:
    swift run --configuration release metalsprockets-gaussian-splat bench | duckdb -markdown -c "SELECT * FROM read_csv_auto('/dev/stdin')"
