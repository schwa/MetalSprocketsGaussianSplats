# ``Splats``

Load Gaussian splat data from PLY, SPZ, and SOG files.

## Overview

`Splats` is the format-decoding layer of MetalSprockets Gaussian Splats. It
reads splat files from disk, converts each record to a common in-memory
representation (``ExtendedSplat``), and provides ``TypedMTLBuffer`` for
uploading splat data to the GPU.

The concrete per-format readers stream splats one at a time, converting each
record to an ``ExtendedSplat``:

```swift
let reader = try SPZReader(url: url)   // or PLYSplatReader
var splats: [ExtendedSplat] = []
try reader.read { _, splat in
    splats.append(splat)
}
```

For rendering, load straight into GPU buffers with `SplatLoader` (in the
`MetalSprocketsGaussianSplats` module), which routes SPZ and SOG through their
GPU decoders and PLY through the CPU reader.

Supported formats:

- **PLY** — the standard Gaussian splatting interchange format, in ASCII
  and binary encodings (``PLYSplatReader``, built on ``PLYReader``).
- **SPZ** — Niantic's compressed splat format (``SPZReader``).
- **SOG** — PlayCanvas' compressed splat format, decoded on the GPU
  (``SOGReaderGPU``).

## Topics

### Reading Splat Files

- ``SplatReaderProtocol``

### Format Readers

- ``PLYSplatReader``
- ``SPZReader``
- ``SOGReaderGPU``

### Splat Representations

- ``GenericSplat``
- ``ExtendedSplat``

### PLY Parsing

- ``PLYReader``

### GPU Buffers

- ``TypedMTLBuffer``
