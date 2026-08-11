# spark-screenshot

CLI tool for taking screenshots of 3D Gaussian Splatting renders using [sparkjs](https://sparkjs.dev/).

## Installation

### Local Development

Clone the repository and install dependencies:

```bash
git clone <repository-url>
cd spark-screenshot
npm install
```

Run the tool:

```bash
node index.js --splat <path-to-splat-file> [options]
```

### Global Installation

Install globally to use the `spark-screenshot` command from anywhere:

```bash
npm install -g .
```

Or from npm (if published):

```bash
npm install -g spark-screenshot
```

Then use:

```bash
spark-screenshot --splat <path-to-splat-file> [options]
```

## Usage

```bash
spark-screenshot --splat <path-to-splat-file> [options]
```

### Options

- `--splat <path>` - Path to splat file (.splat, .ply, .spz) to render
- `--config <path>` - Path to JSON configuration file
- `--background <rgba>` - Background color in RGBA format (e.g., 0,0,0,1 for black) (default: 0,0,0,1)
- `--width <number>` - Width of the output image (default: 1024)
- `--height <number>` - Height of the output image (default: 768)
- `--output <path>` - Output PNG file path (default: output.png)
- `--model-position <x,y,z>` - Model position in x,y,z format (e.g., 0,0,0)
- `--camera-position <x,y,z>` - Camera position in x,y,z format (e.g., 0,0,1.5)
- `--camera-lookat <x,y,z>` - Camera look-at target in x,y,z format (e.g., 0,0,0)
- `--camera-rotation <values>` - Camera rotation as quaternion (x,y,z,w) or 3x3 matrix (9 values comma-separated)
- `--camera-matrix <values>` - Camera-to-world matrix, 16 comma-separated column-major values. Overrides every other camera flag.
- `--projection-fov <degrees>` - Projection field of view in degrees
- `--near <number>` - Camera near clipping plane (default: 0.1)
- `--far <number>` - Camera far clipping plane (default: 100.0)
- `--srgb-to-linear` - Convert sRGB to linear in fragment shader
- `--label` - Render settings label on top of the image
- `--sh-degree <number>` - Override SH degree (0=off, 1-3=use specified degree)
- `--reveal` - Reveal output file in Finder after rendering
- `--port <number>` - Port for local server (default: 8765)

### Configuration File

You can use a JSON configuration file instead of command-line arguments:

```json
{
  "splat": "./my-splat.spz",
  "width": 1920,
  "height": 1080,
  "output": "render.png",
  "background": [0, 0, 0, 1],
  "cameraPosition": [0, 0, 5],
  "cameraLookat": [0, 0, 0],
  "projectionFov": 60,
  "near": 0.1,
  "far": 100.0
}
```

Then run:

```bash
spark-screenshot --config config.json
```

CLI arguments override config file values.

### Examples

Basic usage:
```bash
spark-screenshot --splat ./my-splat.ply
```

Custom dimensions and camera:
```bash
spark-screenshot --splat ./my-splat.ply --width 1920 --height 1080 --camera-position 0,2,5 --camera-lookat 0,0,0
```

With label overlay:
```bash
spark-screenshot --splat ./my-splat.ply --label --output labeled.png
```

Using a config file with overrides:
```bash
spark-screenshot --config render-config.json --width 2048 --output high-res.png
```

Reveal in Finder after rendering:
```bash
spark-screenshot --splat ./butterfly.spz --reveal
```

## Supported Formats

The tool supports all formats supported by sparkjs:
- `.ply` - PLY files
- `.splat` - Splat files
- `.spz` - SPZ files
- `.ksplat` - KSplat files
- `.sogs` - SOGS files

## How it Works

1. Starts a local HTTP server to serve the splat file and renderer
2. Launches a headless browser using Puppeteer
3. Loads the splat file using sparkjs/THREE.js
4. Renders the scene with specified camera settings
5. Optionally adds a label overlay with render settings
6. Captures a screenshot
7. Saves to the specified output path

## Requirements

- Node.js (v18 or higher recommended)
- npm

## License

MIT
