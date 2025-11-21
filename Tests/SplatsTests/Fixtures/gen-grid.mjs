class Generator {
    constructor(width, height, spacing, s) {
        this.count = width * height;

        // Base columns
        this.columnNames = [
            'x', 'y', 'z',
            'scale_0', 'scale_1', 'scale_2',
            'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity',
            'rot_0', 'rot_1', 'rot_2', 'rot_3'
        ];

        // Add SH coefficients (degree 1 = 3 coeffs per channel = 9 total)
        for (let i = 0; i < 9; i++) {
            this.columnNames.push(`f_rest_${i}`);
        }

        const SH_C0 = 0.28209479177387814;
        const packClr = (c) => (c - 0.5) / SH_C0;
        const packOpacity = (opacity) => (opacity <= 0) ? -20 : (opacity >= 1) ? 20 : -Math.log(1 / opacity - 1);

        const gs = Math.log(s);

        // Predefined rotations to test all iLargest cases
        // Format: [w, x, y, z] (standard 3DGS PLY order)
        const rotations = [
            [1, 0, 0, 0],                           // Identity (W largest)
            [0.707107, 0.707107, 0, 0],             // 90° around X (W/X equal)
            [0.707107, 0, 0.707107, 0],             // 90° around Y (W/Y equal)
            [0.707107, 0, 0, 0.707107],             // 90° around Z (W/Z equal)
            [0, 1, 0, 0],                           // 180° around X (X largest)
            [0, 0, 1, 0],                           // 180° around Y (Y largest)
            [0, 0, 0, 1],                           // 180° around Z (Z largest)
            [0.5, 0.5, 0.5, 0.5],                   // 120° around (1,1,1) (all equal)
            [0.653, 0.271, 0.653, 0.271],           // Arbitrary rotation
            [0.683, 0.183, 0.183, 0.683],           // Another arbitrary
        ];

        // Predefined colors (RGB 0-1)
        const colors = [
            [1, 0, 0],     // Red
            [0, 1, 0],     // Green
            [0, 0, 1],     // Blue
            [1, 1, 0],     // Yellow
            [1, 0, 1],     // Magenta
            [0, 1, 1],     // Cyan
            [1, 1, 1],     // White
            [0.5, 0.5, 0.5], // Gray
            [1, 0.5, 0],   // Orange
            [0.5, 0, 1],   // Purple
        ];

        // Predefined alphas (0-1)
        const alphas = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1];

        this.getRow = (index, row) => {
            row.x = ((index % width) - width * 0.5) * spacing;
            row.y = 0;
            row.z = (Math.floor(index / width) - height * 0.5) * spacing;

            row.scale_0 = gs;
            row.scale_1 = gs;
            row.scale_2 = gs;

            // Cycle through colors
            const color = colors[index % colors.length];
            row.f_dc_0 = packClr(color[0]);
            row.f_dc_1 = packClr(color[1]);
            row.f_dc_2 = packClr(color[2]);

            // Cycle through alphas
            row.opacity = packOpacity(alphas[index % alphas.length]);

            // Cycle through rotations
            const rot = rotations[index % rotations.length];
            row.rot_0 = rot[0];
            row.rot_1 = rot[1];
            row.rot_2 = rot[2];
            row.rot_3 = rot[3];

            // SH coefficients (degree 1 = 3 coeffs, 3 channels = 9 values)
            // Use small varied values for testing
            for (let i = 0; i < 9; i++) {
                row[`f_rest_${i}`] = ((index + i) % 20 - 10) * 0.01;
            }
        };
    }

    static create(params) {
        const floatParam = (name, defaultValue) => parseFloat(params.find(p => p.name === name)?.value ?? defaultValue);

        const w = Math.floor(floatParam('width', 1000));
        const h = Math.floor(floatParam('height', 1000));
        const spacing = floatParam('spacing', 1.0);
        const s = floatParam('scale', 0.1);

        console.log(`Generating grid width=${w} height=${h} spacing=${spacing} scale=${s}`);

        return new Generator(w, h, spacing, s);
    }
};

export { Generator };
