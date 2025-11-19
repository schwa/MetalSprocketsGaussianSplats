list:
    @just --list

render CONFIG OUTPUT:
    swift run --configuration release gsplat-render --config "{{ CONFIG }}" --output "{{ OUTPUT }}"

render-all:
    just render "Samples/butterfly-wings-closed.json" "tmp/butterfly-wings-closed.png"
