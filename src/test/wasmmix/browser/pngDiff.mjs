// Cross-backend pixel bound of void docs/TESTING.md "Guardrail 9": a delta of 1 is ignored; FAIL at
// a max delta of 4 or more, or when more than 0.05% of pixels sit at delta 2-3.
//
//   node pngDiff.mjs <a.png> <b.png>
//   node pngDiff.mjs --self-test
//
// decodePng is copied from void/scripts/webPresent.mjs (8-bit RGB/RGBA, non-interlaced), plus an
// encoder for the self-test.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { deflateSync, inflateSync } from 'node:zlib';

const failDelta = 4;
const maxShare = 0.0005;

export function decodePng(bytes) {
	const view = Buffer.from(bytes);
	if (view.readUInt32BE(0) !== 0x89504e47) throw new Error('not a PNG');
	let width = 0, height = 0, channels = 0;
	const data = [];
	for (let at = 8; at < view.length;) {
		const length = view.readUInt32BE(at);
		const kind = view.toString('latin1', at + 4, at + 8);
		const body = view.subarray(at + 8, at + 8 + length);
		if (kind === 'IHDR') {
			width = body.readUInt32BE(0);
			height = body.readUInt32BE(4);
			const depth = body[8], colour = body[9], interlace = body[12];
			channels = colour === 6 ? 4 : colour === 2 ? 3 : 0;
			if (depth !== 8 || channels === 0 || interlace !== 0) {
				throw new Error(`PNG depth ${depth}, colour type ${colour}, interlace ${interlace}: only 8-bit RGB/RGBA, non-interlaced`);
			}
		} else if (kind === 'IDAT') {
			data.push(body);
		}
		at += 12 + length;
	}
	const raw = inflateSync(Buffer.concat(data));
	const stride = width * channels;
	const pixels = Buffer.alloc(height * stride);
	for (let y = 0; y < height; y++) {
		const filter = raw[y * (stride + 1)];
		const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
		for (let x = 0; x < stride; x++) {
			const left = x >= channels ? pixels[y * stride + x - channels] : 0;
			const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
			const upLeft = x >= channels && y > 0 ? pixels[(y - 1) * stride + x - channels] : 0;
			let value = line[x];
			if (filter === 1) value += left;
			else if (filter === 2) value += up;
			else if (filter === 3) value += (left + up) >> 1;
			else if (filter === 4) {
				const p = left + up - upLeft;
				const pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - upLeft);
				value += pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
			} else if (filter !== 0) throw new Error(`PNG filter ${filter} on row ${y}`);
			pixels[y * stride + x] = value & 0xff;
		}
	}
	return { width, height, channels, pixels };
}

export function compare(a, b) {
	if (a.width !== b.width || a.height !== b.height) {
		return { pass: false, reason: `size ${a.width}x${a.height} vs ${b.width}x${b.height}`, maxDelta: Infinity, share: 1 };
	}
	let maxDelta = 0, mid = 0;
	for (let i = 0; i < a.width * a.height; i++) {
		let worst = 0;
		for (let c = 0; c < 3; c++) worst = Math.max(worst, Math.abs(a.pixels[i * a.channels + c] - b.pixels[i * b.channels + c]));
		maxDelta = Math.max(maxDelta, worst);
		if (worst === 2 || worst === 3) mid++;
	}
	const share = a.width * a.height === 0 ? 0 : mid / (a.width * a.height);
	return { pass: maxDelta < failDelta && share <= maxShare, maxDelta, share };
}

const line = (r) => `${r.pass ? 'PASS' : 'FAIL'}  max delta ${r.maxDelta}, ${(r.share * 100).toFixed(4)}% of pixels at delta 2-3${r.reason ? ` (${r.reason})` : ''}`;

function crc32(buf) {
	let c = ~0;
	for (const byte of buf) {
		c ^= byte;
		for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
	}
	return ~c >>> 0;
}

function encodePng({ width, height, pixels }) {
	const chunk = (kind, body) => {
		const out = Buffer.alloc(12 + body.length);
		out.writeUInt32BE(body.length, 0);
		out.write(kind, 4, 'latin1');
		body.copy(out, 8);
		out.writeUInt32BE(crc32(out.subarray(4, 8 + body.length)), 8 + body.length);
		return out;
	};
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(width, 0);
	ihdr.writeUInt32BE(height, 4);
	ihdr[8] = 8;
	ihdr[9] = 2;
	const raw = Buffer.alloc(height * (width * 3 + 1));
	for (let y = 0; y < height; y++) pixels.copy(raw, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
	return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

function selfTest() {
	const width = 100, height = 100;
	const make = (edit) => {
		const pixels = Buffer.alloc(width * height * 3, 100);
		edit(pixels);
		return encodePng({ width, height, pixels });
	};
	const base = make(() => {});
	const cases = [
		['identical', base, true],
		['delta 1 everywhere', make((p) => p.fill(101)), true],
		['one pixel delta 4', make((p) => { p[0] = 104; }), false],
		['0.06% of pixels at delta 2', make((p) => { for (let i = 0; i < 6; i++) p[i * 3] = 102; }), false],
		['0.05% of pixels at delta 2', make((p) => { for (let i = 0; i < 5; i++) p[i * 3] = 102; }), true],
	];
	let bad = 0;
	for (const [name, png, want] of cases) {
		const r = compare(decodePng(base), decodePng(png));
		const ok = r.pass === want;
		if (!ok) bad++;
		console.log(`${ok ? 'ok  ' : 'BAD '} ${name}: ${line(r)}`);
	}
	console.log(bad === 0 ? 'self-test PASS' : `self-test FAIL (${bad})`);
	return bad === 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
	const args = process.argv.slice(2);
	if (args[0] === '--self-test') process.exitCode = selfTest() ? 0 : 1;
	else if (args.length !== 2) {
		console.error('usage: node pngDiff.mjs <a.png> <b.png> | --self-test');
		process.exitCode = 2;
	} else {
		const r = compare(decodePng(readFileSync(args[0])), decodePng(readFileSync(args[1])));
		console.log(line(r));
		process.exitCode = r.pass ? 0 : 1;
	}
}
