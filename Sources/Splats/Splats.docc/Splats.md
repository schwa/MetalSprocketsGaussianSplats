# ``Splats``

Load Gaussian splat data from PLY, SPZ, and SOG files.

## Overview

`Splats` is the format-decoding layer of MetalSprockets Gaussian Splats. It
reads splat files from disk, converts each record to a common in-memory
representation (``ExtendedSplat``), and provides ``TypedMTLBuffer`` for
uploading splat data to the GPU.

The simplest entry point is ``SplatReader``, which picks the correct
format reader from the file extension:

```swift
let reader = try SplatReader(url: url)
var splats: [ExtendedSplat] = []
try reader.read { _, splat in
    splats.append(splat)
}
```

Supported formats:

- **PLY** — the standard Gaussian splatting interchange format, in ASCII
  and binary encodings (``PLYSplatReader``, built on ``PLYReader``).
- **SPZ** — Niantic's compressed splat format (``SPZReader``).
- **SOG** — PlayCanvas' compressed splat format, decoded on the CPU
  (``SOGReaderCPU``) or the GPU (``SOGReaderGPU``).

## Topics

### Reading Splat Files

- ``SplatReader``
- ``SplatReaderProtocol``

### Format Readers

- ``PLYSplatReader``
- ``SPZReader``
- ``SOGReaderCPU``
- ``SOGReaderGPU``

### Splat Representations

- ``GenericSplat``
- ``ExtendedSplat``

### PLY Parsing

- ``PLYReader``

### GPU Buffers

- ``TypedMTLBuffer``
