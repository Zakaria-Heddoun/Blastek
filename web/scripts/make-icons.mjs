// Generates the PWA icons from the Blastek mark (rounded square + sparkle).
// Rasterised here rather than committed as opaque binaries so the brand colours
// live in one place and the set can be regenerated: `node scripts/make-icons.mjs`.
import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'icons');

const INK = [0x2a, 0x0a, 0x12]; // brand burgundy
const GOLD = [0xd8, 0xb8, 0x8a];

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};

const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
};

function png(size, pixel) {
  // One filter byte (0 = none) per scanline, then RGB triples.
  const raw = Buffer.alloc(size * (size * 3 + 1));
  let p = 0;
  for (let y = 0; y < size; y++) {
    raw[p++] = 0;
    for (let x = 0; x < size; x++) {
      const [r, g, b] = pixel(x, y, size);
      raw[p++] = r;
      raw[p++] = g;
      raw[p++] = b;
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: truecolour

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// The four-pointed sparkle: an astroid, |x|^(2/3) + |y|^(2/3) <= 1.
const inSparkle = (nx, ny, scale) => {
  const x = Math.abs(nx) / scale;
  const y = Math.abs(ny) / scale;
  return Math.pow(x, 2 / 3) + Math.pow(y, 2 / 3) <= 1;
};

const inRoundedSquare = (x, y, size, radius) => {
  const dx = Math.max(radius - x, 0, x - (size - radius));
  const dy = Math.max(radius - y, 0, y - (size - radius));
  return dx * dx + dy * dy <= radius * radius;
};

function draw({ size, sparkleScale, rounded }) {
  return (x, y) => {
    const cx = (x + 0.5 - size / 2) / (size / 2);
    const cy = (y + 0.5 - size / 2) / (size / 2);

    // Maskable icons are full-bleed: the launcher crops them to its own shape.
    if (rounded && !inRoundedSquare(x + 0.5, y + 0.5, size, size * 0.25)) {
      return [255, 255, 255];
    }
    return inSparkle(cx, cy, sparkleScale) ? GOLD : INK;
  };
}

mkdirSync(OUT, { recursive: true });

const icons = [
  ['icon-192.png', { size: 192, sparkleScale: 0.72, rounded: true }],
  ['icon-512.png', { size: 512, sparkleScale: 0.72, rounded: true }],
  // Smaller glyph so it survives the launcher's safe-zone crop.
  ['icon-maskable-512.png', { size: 512, sparkleScale: 0.5, rounded: false }],
];

for (const [name, opts] of icons) {
  writeFileSync(join(OUT, name), png(opts.size, draw(opts)));
  console.log(`wrote ${name} (${opts.size}x${opts.size})`);
}
