list:
    @just --list

build:
    swift build --configuration release

render-all: build
    .build/release/gsplat-render --config "Samples/butterfly-wings-closed.json" --output "tmp/butterfly-wings-closed_Spark_SH3.png" --renderer "Spark" --label
    .build/release/gsplat-render --config "Samples/butterfly-wings-closed.json" --output "tmp/butterfly-wings-closed_Spark_SH2.png" --renderer "Spark" --label --sh-degree 2
    .build/release/gsplat-render --config "Samples/butterfly-wings-closed.json" --output "tmp/butterfly-wings-closed_Spark_SH1.png" --renderer "Spark" --label --sh-degree 1
    .build/release/gsplat-render --config "Samples/butterfly-wings-closed.json" --output "tmp/butterfly-wings-closed_Spark_SH0.png" --renderer "Spark" --label --sh-degree 0
    .build/release/gsplat-render --config "Samples/butterfly-wings-closed.json" --output "tmp/butterfly-wings-closed_Antimatter15.png" --renderer "Antimatter15" --label
    command -v spark-screenshot > /dev/null && spark-screenshot --config "Samples/butterfly-wings-closed.json" --output "tmp/butterfly-wings-closed_SparkJS.png" --label || true
