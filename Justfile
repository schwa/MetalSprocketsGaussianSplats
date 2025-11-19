list:
    @just --list

render CONFIG OUTPUT RENDERER *ARGS:
    swift run --configuration release gsplat-render --config "{{ CONFIG }}" --output "{{ OUTPUT }}" --renderer "{{ RENDERER }}" --label {{ ARGS }}

render-all:
    just render "Samples/butterfly-wings-closed.json" "tmp/butterfly-wings-closed_Spark.png" "Spark"
    just render "Samples/butterfly-wings-closed.json" "tmp/butterfly-wings-closed_Spark_SH0.png" "Spark" "--sh-degree 0"
    just render "Samples/butterfly-wings-closed.json" "tmp/butterfly-wings-closed_Antimatter15.png" "Antimatter15"
