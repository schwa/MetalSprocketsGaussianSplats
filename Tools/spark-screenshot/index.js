#!/usr/bin/env node

import { Command } from 'commander';
import puppeteer from 'puppeteer';
import { createServer } from 'http';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { resolve, dirname, basename } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const program = new Command();

program
  .name('spark-screenshot')
  .description('CLI tool for taking screenshots of 3D Gaussian Splatting renders using sparkjs')
  .version('1.0.0')
  .option('--background <rgba>', 'Background color in RGBA format (e.g., 0,0,0,1 for black)', '0,0,0,1')
  .option('--width <number>', 'Width of the output image', '1024')
  .option('--height <number>', 'Height of the output image', '768')
  .option('--output <path>', 'Output PNG file path', 'output.png')
  .option('--model-position <x,y,z>', 'Model position in x,y,z format (e.g., 0,0,0)')
  .option('--camera-position <x,y,z>', 'Camera position in x,y,z format (e.g., 0,0,1.5)')
  .option('--camera-lookat <x,y,z>', 'Camera look-at target in x,y,z format (e.g., 0,0,0)')
  .option('--camera-rotation <values>', 'Camera rotation as quaternion (x,y,z,w) or 3x3 matrix (9 values comma-separated)')
  .option('--camera-matrix <values>', 'Camera-to-world matrix, 16 comma-separated column-major values. Overrides every other camera flag.')
  .option('--projection-fov <degrees>', 'Projection field of view in degrees')
  .option('--near <number>', 'Camera near clipping plane', '0.1')
  .option('--far <number>', 'Camera far clipping plane', '100.0')
  .option('--splat <path>', 'Path to splat file (.splat, .ply, .spz) to render')
  .option('--config <path>', 'Path to JSON configuration file')
  .option('--srgb-to-linear', 'Convert sRGB to linear in fragment shader')
  .option('--label', 'Render settings label on top of the image')
  .option('--sh-degree <number>', 'Override SH degree (0=off, 1-3=use specified degree)')
  .option('--reveal', 'Reveal output file in Finder after rendering')
  .option('--port <number>', 'Port for local server', '8765')
  .parse(process.argv);

const cliOptions = program.opts();

// Load config from file if specified
let config = {
  background: [0, 0, 0, 1],
  width: 1024,
  height: 768,
  output: 'output.png',
  modelPosition: null,
  cameraPosition: null,
  cameraLookat: null,
  cameraRotation: null,
  cameraMatrix: null,
  projectionFov: null,
  near: 0.1,
  far: 100.0,
  splat: null,
  srgbToLinear: false
};

if (cliOptions.config) {
  const configPath = resolve(cliOptions.config);
  if (!existsSync(configPath)) {
    console.error(`Error: Config file not found: ${configPath}`);
    process.exit(1);
  }
  try {
    const configData = JSON.parse(readFileSync(configPath, 'utf8'));
    config = { ...config, ...configData };
  } catch (error) {
    console.error(`Error parsing config file: ${error.message}`);
    process.exit(1);
  }
}

// CLI flags override config values
if (cliOptions.background !== '0,0,0,1') {
  const parts = cliOptions.background.split(',').map(s => parseFloat(s.trim()));
  if (parts.length === 4) {
    config.background = parts;
  }
}
if (cliOptions.width !== '1024') config.width = parseInt(cliOptions.width);
if (cliOptions.height !== '768') config.height = parseInt(cliOptions.height);
if (cliOptions.output !== 'output.png') config.output = cliOptions.output;
if (cliOptions.modelPosition) {
  const parts = cliOptions.modelPosition.split(',').map(s => parseFloat(s.trim()));
  if (parts.length === 3) config.modelPosition = parts;
}
if (cliOptions.cameraPosition) {
  const parts = cliOptions.cameraPosition.split(',').map(s => parseFloat(s.trim()));
  if (parts.length === 3) config.cameraPosition = parts;
}
if (cliOptions.cameraLookat) {
  const parts = cliOptions.cameraLookat.split(',').map(s => parseFloat(s.trim()));
  if (parts.length === 3) config.cameraLookat = parts;
}
null
if (cliOptions.cameraRotation) {
  const parts = cliOptions.cameraRotation.split(',').map(s => parseFloat(s.trim()));
  if (parts.length !== 4 && parts.length !== 9) {
    console.error('Error: Camera rotation must be either 4 values (quaternion x,y,z,w) or 9 values (3x3 matrix)');
    process.exit(1);
  }
  config.cameraRotation = parts;
}
if (cliOptions.cameraMatrix) {
  const parts = cliOptions.cameraMatrix.split(',').map(s => parseFloat(s.trim()));
  if (parts.length !== 16) {
    console.error('Error: Camera matrix must be 16 comma-separated values');
    process.exit(1);
  }
  config.cameraMatrix = parts;
}
if (cliOptions.srgbToLinear) config.srgbToLinear = true;
if (cliOptions.projectionFov) config.projectionFov = parseFloat(cliOptions.projectionFov);
if (cliOptions.near !== '0.1') config.near = parseFloat(cliOptions.near);
if (cliOptions.far !== '100.0') config.far = parseFloat(cliOptions.far);
if (cliOptions.splat) config.splat = cliOptions.splat;

if (config.cameraMatrix && (config.cameraPosition || config.cameraLookat || config.cameraRotation)) {
  console.error('Error: --camera-matrix is the whole camera; it cannot be combined with --camera-position, --camera-lookat, or --camera-rotation');
  process.exit(1);
}

// Validate splat file
if (!config.splat) {
  console.error('Error: Must specify a splat file with --splat or use --config');
  process.exit(1);
}

const splatPath = resolve(config.splat);
if (!existsSync(splatPath)) {
  console.error(`Error: Splat file not found: ${splatPath}`);
  process.exit(1);
}

// Parse numeric options
const width = config.width;
const height = config.height;
const port = parseInt(cliOptions.port);

if (isNaN(width) || isNaN(height) || width <= 0 || height <= 0) {
  console.error('Error: Width and height must be positive numbers');
  process.exit(1);
}

// Spark detects antimatter15 .splat files by URL extension only (no magic
// bytes), so the served path must keep the original extension.
const splatExt = basename(splatPath).split('.').pop().toLowerCase();
const splatUrlPath = `/splat.${splatExt}`;

// Create a simple HTTP server to serve files
const server = createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);

  if (url.pathname === '/') {
    // Serve the render.html file
    const html = readFileSync(resolve(__dirname, 'render.html'), 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
  } else if (url.pathname === splatUrlPath) {
    // Serve the splat file
    try {
      const splatData = readFileSync(splatPath);
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Access-Control-Allow-Origin': '*'
      });
      res.end(splatData);
    } catch (error) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end(`Error loading splat file: ${error.message}`);
    }
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
});

server.listen(port, async () => {
  try {
    // Launch puppeteer
    const browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-web-security']
    });

    const page = await browser.newPage();
    await page.setViewport({ width, height });

    // Set up console message logging
    page.on('console', msg => {
      const type = msg.type();
      if (type === 'error') {
        console.error('Browser error:', msg.text());
      }
    });

    // Build URL with parameters
    // Convert config to URL params
    const bgRgb = config.background.slice(0, 3).map(v => Math.round(v * 255)).join(',');
    const fov = config.projectionFov || 60;
    const shDegree = cliOptions.shDegree ? parseInt(cliOptions.shDegree) : null;

    const urlParams = new URLSearchParams({
      splat: `http://localhost:${port}${splatUrlPath}`,
      width, height, fov,
      near: config.near,
      far: config.far,
      backgroundColor: bgRgb,
      colorSpace: config.srgbToLinear ? 'linear' : 'srgb'
    });
    if (config.cameraPosition) urlParams.set('cameraPosition', config.cameraPosition.join(','));
    if (config.cameraLookat) urlParams.set('lookAt', config.cameraLookat.join(','));
    if (config.cameraRotation) urlParams.set('cameraRotation', config.cameraRotation.join(','));
    if (config.cameraMatrix) urlParams.set('cameraMatrix', config.cameraMatrix.join(','));
    if (config.modelPosition) urlParams.set('modelPosition', config.modelPosition.join(','));
    if (shDegree !== null) urlParams.set('shDegree', shDegree);

    const renderUrl = `http://localhost:${port}/?${urlParams}`;
    await page.goto(renderUrl, { waitUntil: 'networkidle0' });

    // Wait for render to complete
    await page.waitForFunction(
      () => window.renderComplete === true,
      { timeout: 30000 }
    );

    // Check for errors
    const renderError = await page.evaluate(() => window.renderError);
    if (renderError) {
      throw new Error(`Render error: ${renderError}`);
    }

    // Get splat count from page if available
    const splatCount = await page.evaluate(() => window.splatCount || 'unknown');

    // Add label overlay if requested
    if (cliOptions.label) {
      const camPos = config.cameraPosition || [0, 0, 1.5];
      const modelPos = config.modelPosition || [0, 0, 0];
      const fovStr = (config.projectionFov || 60).toFixed(1) + '°';

      const labelText = `Renderer: SparkJS
Size: ${width}x${height} | FOV: ${fovStr}
Splats: ${splatCount} | Near/Far: ${config.near}/${config.far}
Camera: (${camPos[0].toFixed(2)}, ${camPos[1].toFixed(2)}, ${camPos[2].toFixed(2)})
Model: (${modelPos[0].toFixed(2)}, ${modelPos[1].toFixed(2)}, ${modelPos[2].toFixed(2)})`;

      await page.evaluate((text) => {
        const label = document.createElement('div');
        label.style.cssText = `
          position: fixed;
          bottom: 10px;
          left: 10px;
          background: rgba(0, 0, 0, 0.7);
          color: white;
          font-family: monospace;
          font-size: 12px;
          padding: 8px;
          border-radius: 4px;
          white-space: pre;
          z-index: 10000;
        `;
        label.textContent = text;
        document.body.appendChild(label);
      }, labelText);
    }

    // Take screenshot
    const outputPath = resolve(config.output);
    await page.screenshot({
      path: outputPath,
      type: 'png'
    });

    await browser.close();
    server.close();

    // Reveal in Finder if requested
    if (cliOptions.reveal) {
      try {
        execSync(`open -R "${outputPath}"`);
      } catch (e) {
        // Ignore errors
      }
    }

    process.exit(0);

  } catch (error) {
    console.error('Error:', error.message);
    server.close();
    process.exit(1);
  }
});
