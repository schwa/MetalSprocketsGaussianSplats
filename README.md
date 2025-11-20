# MetalSprockets Gaussian Splats

Gaussian Splat rendering built on [MetalSprockets](https://metalsprockets/com) ([Github](https://github.com/schwa/MetalSprockets)).

This repository includes both a standalone renderer and a Swift framework you can drop into your own project.

There’s also a CLI target for offline rendering. See the Justfile for how to drive it.

For anyone new the Wikipedia article is a great summary of the technique: [Wikipedia](https://en.wikipedia.org/wiki/Gaussian_splatting)

## Requirements

- Any current iOS device or Apple Silcon Mac.
- Currently requires macOS 26/iOS 26 - but can be backported with minimal effort.

## License

MIT License. See LICENSE file for details.

## Acknowledgments

The two renderers in this project were based on work by the following projects. A big thanks to their authors for releasing their code under permissive licenses.

• [antimatter15](https://github.com/antimatter15/splat) (MIT license) — for the original GS renderer and the reference that basically everyone starts from.
• [sparkjs](http://sparkjs.dev) (MIT License)— for the clean implementation that makes porting sane.
