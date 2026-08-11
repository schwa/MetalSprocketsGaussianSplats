# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "torch",
#     "numpy",
#     "pillow",
#     "plyfile",
#     "typer",
# ]
# ///
"""Pure-PyTorch 3DGS reference renderer for golden-image comparison.

Forward pass follows the INRIA / gsplat conventions:
  - activations: exp(scale), sigmoid(opacity), normalized quaternion
  - EWA splatting Jacobian, 2D covariance + 0.3px dilation (--no-dilation to disable)
  - SH evaluated along world-space view direction, clamped at 0
  - global back-to-front depth sort, per-pixel alpha compositing in f32
  - alpha skip threshold 1/255, transmittance early-out at 1e-4

CLI flags mirror metalsprockets-gaussian-splat where sensible. The camera
matrix is camera-to-world, OpenGL convention (camera looks down -Z, Y up),
column-major when passed as 16 floats.
"""

import hashlib
import json
import math
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

import numpy as np
import torch
import typer
from PIL import Image

app = typer.Typer(add_completion=False)

C0 = 0.28209479177387814


def load_ply(path: Path):
    """Load an INRIA-format 3DGS .ply. Returns dict of numpy arrays."""
    from plyfile import PlyData

    ply = PlyData.read(str(path))
    v = ply["vertex"]
    names = v.data.dtype.names

    def cols(prefix, n):
        return np.stack([np.asarray(v[f"{prefix}{i}"]) for i in range(n)], axis=1)

    xyz = np.stack([np.asarray(v[a]) for a in ("x", "y", "z")], axis=1)
    opacity = np.asarray(v["opacity"])
    scale = cols("scale_", 3)
    rot = cols("rot_", 4)  # (w, x, y, z) in INRIA plys
    f_dc = cols("f_dc_", 3)

    n_rest = len([n for n in names if n.startswith("f_rest_")])
    if n_rest:
        f_rest = cols("f_rest_", n_rest)  # planar: all R coeffs, all G, all B
        m = n_rest // 3
        f_rest = f_rest.reshape(-1, 3, m).transpose(0, 2, 1)  # (N, m, 3)
        sh_degree = int(math.isqrt(m + 1)) - 1
    else:
        f_rest = np.zeros((len(xyz), 0, 3), dtype=np.float32)
        sh_degree = 0

    return dict(
        xyz=xyz.astype(np.float32),
        opacity=opacity.astype(np.float32),
        scale=scale.astype(np.float32),
        rot=rot.astype(np.float32),
        f_dc=f_dc.astype(np.float32),
        f_rest=f_rest.astype(np.float32),
        sh_degree=sh_degree,
    )


# Real SH basis constants (matches INRIA sh_utils.py / gsplat)
SH_C1 = 0.4886025119029199
SH_C2 = [1.0925484305920792, -1.0925484305920792, 0.31539156525252005,
         -1.0925484305920792, 0.5462742152960396]
SH_C3 = [-0.5900435899266435, 2.890611442640554, -0.4570457994644658,
         0.3731763325901154, -0.4570457994644658, 1.445305721320277,
         -0.5900435899266435]


def eval_sh(deg: int, sh: torch.Tensor, dirs: torch.Tensor) -> torch.Tensor:
    """sh: (N, K, 3) with K = (deg+1)^2, dirs: (N, 3) normalized. Returns (N, 3)."""
    result = C0 * sh[:, 0]
    if deg >= 1:
        x, y, z = dirs[:, 0:1], dirs[:, 1:2], dirs[:, 2:3]
        result = (result - SH_C1 * y * sh[:, 1] + SH_C1 * z * sh[:, 2]
                  - SH_C1 * x * sh[:, 3])
        if deg >= 2:
            xx, yy, zz = x * x, y * y, z * z
            xy, yz, xz = x * y, y * z, x * z
            result = (result
                      + SH_C2[0] * xy * sh[:, 4] + SH_C2[1] * yz * sh[:, 5]
                      + SH_C2[2] * (2 * zz - xx - yy) * sh[:, 6]
                      + SH_C2[3] * xz * sh[:, 7] + SH_C2[4] * (xx - yy) * sh[:, 8])
            if deg >= 3:
                result = (result
                          + SH_C3[0] * y * (3 * xx - yy) * sh[:, 9]
                          + SH_C3[1] * xy * z * sh[:, 10]
                          + SH_C3[2] * y * (4 * zz - xx - yy) * sh[:, 11]
                          + SH_C3[3] * z * (2 * zz - 3 * xx - 3 * yy) * sh[:, 12]
                          + SH_C3[4] * x * (4 * zz - xx - yy) * sh[:, 13]
                          + SH_C3[5] * z * (xx - yy) * sh[:, 14]
                          + SH_C3[6] * x * (xx - 3 * yy) * sh[:, 15])
    return result + 0.5


def quat_to_rotmat(q: torch.Tensor) -> torch.Tensor:
    """q: (N, 4) as (w, x, y, z), normalized. Returns (N, 3, 3)."""
    w, x, y, z = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    return torch.stack([
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
    ], dim=1).reshape(-1, 3, 3)


def render(
    splats: dict,
    cam_to_world: np.ndarray,  # (4,4) OpenGL convention
    width: int,
    height: int,
    fov_y_deg: float,
    near: float,
    far: float,
    background: np.ndarray,  # (3,) or (4,)
    sh_degree_override: Optional[int],
    dilation: bool,
    model_translation: np.ndarray,
) -> np.ndarray:
    t = torch.float32
    xyz = torch.from_numpy(splats["xyz"]).to(t) + torch.from_numpy(model_translation).to(t)
    N = xyz.shape[0]

    opacity = torch.sigmoid(torch.from_numpy(splats["opacity"]).to(t))
    scale = torch.exp(torch.from_numpy(splats["scale"]).to(t))
    rot = torch.from_numpy(splats["rot"]).to(t)
    rot = rot / rot.norm(dim=1, keepdim=True)

    deg = splats["sh_degree"] if sh_degree_override is None else sh_degree_override
    K = (deg + 1) ** 2
    sh = torch.cat([
        torch.from_numpy(splats["f_dc"]).to(t).unsqueeze(1),
        torch.from_numpy(splats["f_rest"]).to(t),
    ], dim=1)[:, :K]

    # World-to-camera, converting OpenGL (-Z forward, Y up) to
    # OpenCV (+Z forward, Y down) used by the EWA math below.
    c2w = torch.from_numpy(cam_to_world.astype(np.float32))
    w2c_gl = torch.linalg.inv(c2w)
    flip = torch.diag(torch.tensor([1.0, -1.0, -1.0, 1.0]))
    w2c = flip @ w2c_gl
    R_wc = w2c[:3, :3]
    t_wc = w2c[:3, 3]

    # Intrinsics from vertical FOV
    fy = height / (2 * math.tan(math.radians(fov_y_deg) / 2))
    fx = fy
    cx, cy = width / 2, height / 2

    cam_pos = c2w[:3, 3]

    # SH color along world-space view dir
    dirs = xyz - cam_pos
    dirs = dirs / dirs.norm(dim=1, keepdim=True).clamp(min=1e-8)
    color = eval_sh(deg, sh, dirs).clamp(min=0.0)

    # Project means
    p_cam = (R_wc @ xyz.T).T + t_wc  # (N, 3)
    depth = p_cam[:, 2]
    in_front = (depth > near) & (depth < far)

    z = depth.clamp(min=1e-6)
    px = fx * p_cam[:, 0] / z + cx
    py = fy * p_cam[:, 1] / z + cy

    # 3D covariance: R S S^T R^T
    Rm = quat_to_rotmat(rot)
    S = torch.zeros(N, 3, 3)
    S[:, 0, 0], S[:, 1, 1], S[:, 2, 2] = scale[:, 0], scale[:, 1], scale[:, 2]
    M = Rm @ S
    cov3d = M @ M.transpose(1, 2)

    # EWA Jacobian (with INRIA's frustum clamping of tan values)
    tan_fovx = width / (2 * fx)
    tan_fovy = height / (2 * fy)
    tx = (p_cam[:, 0] / z).clamp(-1.3 * tan_fovx, 1.3 * tan_fovx) * z
    ty = (p_cam[:, 1] / z).clamp(-1.3 * tan_fovy, 1.3 * tan_fovy) * z

    J = torch.zeros(N, 2, 3)
    J[:, 0, 0] = fx / z
    J[:, 0, 2] = -fx * tx / (z * z)
    J[:, 1, 1] = fy / z
    J[:, 1, 2] = -fy * ty / (z * z)

    T = J @ R_wc.unsqueeze(0)  # (N, 2, 3)
    cov2d = T @ cov3d @ T.transpose(1, 2)  # (N, 2, 2)
    if dilation:
        cov2d[:, 0, 0] += 0.3
        cov2d[:, 1, 1] += 0.3

    det = cov2d[:, 0, 0] * cov2d[:, 1, 1] - cov2d[:, 0, 1] * cov2d[:, 1, 0]
    valid = in_front & (det > 0)

    # Conic (inverse of cov2d)
    inv_det = 1.0 / det.clamp(min=1e-12)
    conic_a = cov2d[:, 1, 1] * inv_det
    conic_b = -cov2d[:, 0, 1] * inv_det
    conic_c = cov2d[:, 0, 0] * inv_det

    # 3-sigma screen radius, INRIA style
    mid = 0.5 * (cov2d[:, 0, 0] + cov2d[:, 1, 1])
    lam1 = mid + torch.sqrt((mid * mid - det).clamp(min=0.1))
    radius = torch.ceil(3.0 * torch.sqrt(lam1))
    valid &= (px + radius > 0) & (px - radius < width) & (py + radius > 0) & (py - radius < height)
    valid &= opacity > (1.0 / 255.0)

    idx = torch.nonzero(valid).squeeze(1)
    order = idx[torch.argsort(depth[idx])]  # front-to-back

    img = torch.zeros(height, width, 3)
    transmittance = torch.ones(height, width)

    n = order.numel()
    for count, i in enumerate(order.tolist()):
        r = radius[i].item()
        x0 = max(int(px[i].item() - r), 0)
        x1 = min(int(px[i].item() + r) + 1, width)
        y0 = max(int(py[i].item() - r), 0)
        y1 = min(int(py[i].item() + r) + 1, height)
        if x0 >= x1 or y0 >= y1:
            continue

        Tpatch = transmittance[y0:y1, x0:x1]
        if Tpatch.max() < 1e-4:
            continue

        ys = torch.arange(y0, y1, dtype=t).unsqueeze(1) + 0.5
        xs = torch.arange(x0, x1, dtype=t).unsqueeze(0) + 0.5
        dx = xs - px[i]
        dy = ys - py[i]
        power = -0.5 * (conic_a[i] * dx * dx + conic_c[i] * dy * dy) - conic_b[i] * dx * dy
        alpha = (opacity[i] * torch.exp(power)).clamp(max=0.99)
        alpha = torch.where(power > 0, torch.zeros_like(alpha), alpha)
        alpha = torch.where(alpha < 1.0 / 255.0, torch.zeros_like(alpha), alpha)

        w = Tpatch * alpha
        img[y0:y1, x0:x1] += w.unsqueeze(-1) * color[i]
        transmittance[y0:y1, x0:x1] = Tpatch * (1 - alpha)

        if count % 5000 == 0:
            print(f"\r  compositing {count}/{n}", end="", flush=True)
    print(f"\r  compositing {n}/{n}")

    bg = torch.tensor(background[:3], dtype=t)
    img = img + transmittance.unsqueeze(-1) * bg
    return img.clamp(0, 1).numpy()


CONVERTIBLE = {".sog", ".spz", ".splat", ".ksplat", ".lcc", ".lcc2"}


def ensure_ply(splat: Path) -> Path:
    """Convert non-.ply inputs to .ply in /tmp via splat-transform (cached by mtime)."""
    if splat.suffix.lower() == ".ply":
        return splat
    if splat.suffix.lower() not in CONVERTIBLE:
        raise typer.BadParameter(f"Unsupported format: {splat.suffix}")
    if shutil.which("splat-transform") is None:
        raise typer.BadParameter("splat-transform not found on PATH (needed to convert non-.ply inputs)")

    key = hashlib.sha256(f"{splat.resolve()}:{splat.stat().st_mtime_ns}".encode()).hexdigest()[:16]
    out = Path(tempfile.gettempdir()) / f"gsplat-golden-{splat.stem}-{key}.ply"
    if not out.exists():
        print(f"Converting {splat.name} -> {out} via splat-transform...")
        subprocess.run(["splat-transform", "-w", str(splat), str(out)], check=True)
    return out


def parse_floats(s: str, n: int, label: str) -> np.ndarray:
    parts = [float(x) for x in s.split(",")]
    if len(parts) != n:
        raise typer.BadParameter(f"{label} must be {n} comma-separated values")
    return np.array(parts, dtype=np.float64)


def look_at(position, target, up=(0.0, 1.0, 0.0)) -> np.ndarray:
    """Camera-to-world, OpenGL convention (-Z forward)."""
    pos = np.asarray(position, dtype=np.float64)
    fwd = np.asarray(target, dtype=np.float64) - pos
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, np.asarray(up, dtype=np.float64))
    right /= np.linalg.norm(right)
    true_up = np.cross(right, fwd)
    m = np.eye(4)
    m[:3, 0] = right
    m[:3, 1] = true_up
    m[:3, 2] = -fwd
    m[:3, 3] = pos
    return m


@app.command()
def main(
    splat: Optional[Path] = typer.Option(None, help="Path to .ply splat file"),
    config: Optional[Path] = typer.Option(None, help="JSON config (same schema as metalsprockets-gaussian-splat)"),
    output: str = typer.Option("output.png", help="Output PNG path"),
    width: int = typer.Option(1024),
    height: int = typer.Option(768),
    background: str = typer.Option("0,0,0,1", help="RGBA background"),
    model_position: Optional[str] = typer.Option(None, help="x,y,z model translation"),
    camera_position: Optional[str] = typer.Option(None, help="x,y,z"),
    camera_lookat: Optional[str] = typer.Option(None, help="x,y,z"),
    camera_matrix: Optional[str] = typer.Option(None, help="16 column-major floats, camera-to-world (OpenGL)"),
    projection_fov: float = typer.Option(60.0, help="Vertical FOV in degrees"),
    near: float = typer.Option(0.1),
    far: float = typer.Option(100.0),
    sh_degree: Optional[int] = typer.Option(None, help="Override SH degree (0-3)"),
    dilation: bool = typer.Option(True, help="Apply INRIA 0.3px covariance dilation"),
    srgb: bool = typer.Option(True, help="Treat splat colors as sRGB (write bytes directly, no conversion)"),
):
    """Render a 3DGS .ply to PNG with a pure-PyTorch reference forward pass."""
    if config is not None:
        cfg = json.loads(config.read_text())
        splat = splat or Path(cfg["splat"])
        width = cfg.get("width", width)
        height = cfg.get("height", height)
        if output == "output.png":  # CLI flag wins over config
            output = cfg.get("output", output)
        projection_fov = cfg.get("projectionFov", projection_fov)
        near = cfg.get("near", near)
        far = cfg.get("far", far)
        if "background" in cfg:
            background = ",".join(str(x) for x in cfg["background"])
        if "cameraPosition" in cfg and camera_position is None:
            camera_position = ",".join(str(x) for x in cfg["cameraPosition"])
        if "cameraLookat" in cfg and camera_lookat is None:
            camera_lookat = ",".join(str(x) for x in cfg["cameraLookat"])
        if "cameraMatrix" in cfg and camera_matrix is None:
            camera_matrix = ",".join(str(x) for x in cfg["cameraMatrix"])
        if "modelPosition" in cfg and model_position is None:
            model_position = ",".join(str(x) for x in cfg["modelPosition"])

    if splat is None:
        raise typer.BadParameter("Must specify --splat or --config")
    splat = ensure_ply(splat)

    bg = parse_floats(background, 4, "background")
    model_t = (parse_floats(model_position, 3, "model position")
               if model_position else np.zeros(3)).astype(np.float32)

    if camera_matrix is not None:
        vals = parse_floats(camera_matrix, 16, "camera matrix")
        c2w = vals.reshape(4, 4, order="F")  # column-major
    elif camera_lookat is not None:
        pos = parse_floats(camera_position, 3, "camera position") if camera_position else np.array([0, 0, 1.5])
        c2w = look_at(pos, parse_floats(camera_lookat, 3, "camera lookat"))
    elif camera_position is not None:
        c2w = np.eye(4)
        c2w[:3, 3] = parse_floats(camera_position, 3, "camera position")
    else:
        c2w = look_at([0, 0, 1.5], [0, 0, 0])

    print(f"Loading {splat}...")
    splats = load_ply(splat)
    print(f"Loaded {len(splats['xyz'])} splats, SH degree {splats['sh_degree']}")

    img = render(splats, c2w, width, height, projection_fov, near, far,
                 bg, sh_degree, dilation, model_t)

    out = Path(output)
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray((img * 255 + 0.5).astype(np.uint8)).save(out)
    print(f"Wrote {out}")


if __name__ == "__main__":
    app()
