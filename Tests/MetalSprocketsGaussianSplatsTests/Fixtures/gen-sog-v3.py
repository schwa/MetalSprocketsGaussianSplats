# Makes the SOG v3 test fixtures. Needs splat-transform 3.11+ (npx).
#
#   uv run Tests/MetalSprocketsGaussianSplatsTests/Fixtures/gen-sog-v3.py
#
# sog-v3-sh4.ply: 256 splats with degree-4 SH and opacity_linear up to 1.5.
# Converted to sog-v3-sh4.sog (v3) and sog-v3-sh4.v2.sog (v2, 3 bands, opacity clamped).
# test-ring.v3.sog / test-ring.v2.sog: test-ring.sog rewritten as v3 and v2. splat-transform
# reorders splats, so both are written by it to keep the same order.
import math
import random
import struct
import subprocess
from pathlib import Path

here = Path(__file__).parent
random.seed(4)
count = 256
rest = 24 * 3
names = ["x", "y", "z", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3",
         "f_dc_0", "f_dc_1", "f_dc_2", "opacity_linear"] + [f"f_rest_{i}" for i in range(rest)]
rows = []
for index in range(count):
    angle = index / count * 2 * math.pi
    q = [random.gauss(0, 1) for _ in range(4)]
    length = math.sqrt(sum(v * v for v in q))
    q = [v / length for v in q]
    opacity = 0.1 + 1.4 * index / (count - 1)
    row = [math.cos(angle), math.sin(angle), 0.1 * math.sin(3 * angle),
           math.log(0.05), math.log(0.02), math.log(0.03), *q,
           random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1), opacity]
    row += [random.uniform(-0.3, 0.3) for _ in range(rest)]
    rows.append(row)

header = "ply\nformat binary_little_endian 1.0\n" + f"element vertex {count}\n"
header += "".join(f"property float {name}\n" for name in names) + "end_header\n"
ply = here / "sog-v3-sh4.ply"
with ply.open("wb") as file:
    file.write(header.encode())
    for row in rows:
        file.write(struct.pack(f"<{len(row)}f", *row))

def convert(source: Path, destination: Path, *extra: str) -> None:
    subprocess.run(["npx", "--yes", "@playcanvas/splat-transform@3.11.1", "-w", *extra, str(source), str(destination)], check=True)

convert(ply, here / "sog-v3-sh4.sog")
convert(ply, here / "sog-v3-sh4.v2.sog", "--sog-version", "2")
convert(here / "test-ring.sog", here / "test-ring.v3.sog")
convert(here / "test-ring.sog", here / "test-ring.v2.sog", "--sog-version", "2")
ply.unlink()
