list:
    @just --list

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
