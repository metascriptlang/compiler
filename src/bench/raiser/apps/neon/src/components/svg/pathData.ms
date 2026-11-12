// SVG path data (SVG 1.1 §8.3, the grammar of `d`) parsed once in MetaScript into
// absolute geometry every host draws the same way: moveto, lineto, cubic and quadratic
// curves and closepath. H/V become lines, S/T become curves with their reflected control
// point, and an elliptical arc becomes cubic curves (implementation notes F.6.5, F.6.6).
// As the specification says, a path renders up to the first error in its data.

export enum PathOp {
	Move,
	Line,
	Cubic,
	Quad,
	Close,
}

// Flat geometry: an op code followed by its absolute points
// (Move x y, Line x y, Cubic x1 y1 x2 y2 x y, Quad x1 y1 x y, Close).
export interface Geometry {
	data: float64[];
}

export function emptyGeometry(): Geometry {
	return { data: [] };
}

export function opArity(op: PathOp): int32 {
	return match (op) {
		PathOp.Move => 2,
		PathOp.Line => 2,
		PathOp.Cubic => 6,
		PathOp.Quad => 4,
		PathOp.Close => 0,
	};
}

export function moveTo(g: Geometry, x: float64, y: float64): void {
	g.data.push(PathOp.Move as int32 as float64);
	g.data.push(x);
	g.data.push(y);
}

export function lineTo(g: Geometry, x: float64, y: float64): void {
	g.data.push(PathOp.Line as int32 as float64);
	g.data.push(x);
	g.data.push(y);
}

export function cubicTo(g: Geometry, x1: float64, y1: float64, x2: float64, y2: float64, x: float64, y: float64): void {
	g.data.push(PathOp.Cubic as int32 as float64);
	g.data.push(x1);
	g.data.push(y1);
	g.data.push(x2);
	g.data.push(y2);
	g.data.push(x);
	g.data.push(y);
}

export function quadTo(g: Geometry, x1: float64, y1: float64, x: float64, y: float64): void {
	g.data.push(PathOp.Quad as int32 as float64);
	g.data.push(x1);
	g.data.push(y1);
	g.data.push(x);
	g.data.push(y);
}

export function closePath(g: Geometry): void {
	g.data.push(PathOp.Close as int32 as float64);
}

struct PathCursor {
	text: string;
	at: int32;
}

function isSpace(code: int32): boolean {
	return code === 32 || code === 9 || code === 10 || code === 12 || code === 13;
}

function isDigit(code: int32): boolean {
	return code >= 48 && code <= 57;
}

function skipSpace(ref c: PathCursor): void {
	while (c.at < c.text.length && isSpace(c.text.charCodeAt(c.at))) { c.at += 1; }
}

function skipSeparator(ref c: PathCursor): void {
	skipSpace(c);
	if (c.at < c.text.length && c.text.charCodeAt(c.at) === 44) {
		c.at += 1;
		skipSpace(c);
	}
}

function codeAt(c: PathCursor): int32 {
	return c.at < c.text.length ? c.text.charCodeAt(c.at) : -1;
}

enum PathError {
	NoNumber,
	BadFlag,
}

function readNumber(ref c: PathCursor): Result<float64, PathError> {
	skipSpace(c);
	const start = c.at;
	let code = codeAt(c);
	if (code === 43 || code === 45) {
		c.at += 1;
		code = codeAt(c);
	}
	let digits = 0;
	while (isDigit(codeAt(c))) {
		c.at += 1;
		digits += 1;
	}
	if (codeAt(c) === 46) {
		c.at += 1;
		while (isDigit(codeAt(c))) {
			c.at += 1;
			digits += 1;
		}
	}
	if (digits === 0) {
		c.at = start;
		return Result.err(PathError.NoNumber);
	}
	const e = codeAt(c);
	if (e === 101 || e === 69) {
		const mark = c.at;
		c.at += 1;
		const sign = codeAt(c);
		if (sign === 43 || sign === 45) { c.at += 1; }
		if (!isDigit(codeAt(c))) {
			c.at = mark;
		} else {
			while (isDigit(codeAt(c))) { c.at += 1; }
		}
	}
	const value = parseFloat(c.text.substring(start, c.at));
	skipSeparator(c);
	return Result.ok(value);
}

function readFlag(ref c: PathCursor): Result<boolean, PathError> {
	skipSpace(c);
	const code = codeAt(c);
	if (code !== 48 && code !== 49) { return Result.err(PathError.BadFlag); }
	c.at += 1;
	skipSeparator(c);
	return Result.ok(code === 49);
}

function startsNumber(c: PathCursor): boolean {
	const code = codeAt(c);
	return isDigit(code) || code === 43 || code === 45 || code === 46;
}

struct PenState {
	x: float64;
	y: float64;
	startX: float64;
	startY: float64;
	controlX: float64;
	controlY: float64;
	lastCubic: boolean;
	lastQuad: boolean;
}

function vectorAngle(ux: float64, uy: float64, vx: float64, vy: float64): float64 {
	return Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

// Implementation notes F.6.5 (endpoint to centre parameterisation) and F.6.6 (radii
// correction), then one cubic per quarter turn or less.
export function arcTo(
	g: Geometry,
	x1: float64,
	y1: float64,
	radiusX: float64,
	radiusY: float64,
	rotationDegrees: float64,
	largeArc: boolean,
	sweep: boolean,
	x2: float64,
	y2: float64,
): void {
	if (x1 === x2 && y1 === y2) { return; }
	let rx = Math.abs(radiusX);
	let ry = Math.abs(radiusY);
	if (rx === 0 || ry === 0) {
		lineTo(g, x2, y2);
		return;
	}
	const phi = rotationDegrees * Math.PI / 180;
	const cosPhi = Math.cos(phi);
	const sinPhi = Math.sin(phi);
	const halfX = (x1 - x2) / 2;
	const halfY = (y1 - y2) / 2;
	const x1p = cosPhi * halfX + sinPhi * halfY;
	const y1p = -sinPhi * halfX + cosPhi * halfY;
	const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
	if (lambda > 1) {
		const grow = Math.sqrt(lambda);
		rx *= grow;
		ry *= grow;
	}
	const rxSq = rx * rx;
	const rySq = ry * ry;
	const numerator = rxSq * rySq - rxSq * y1p * y1p - rySq * x1p * x1p;
	const denominator = rxSq * y1p * y1p + rySq * x1p * x1p;
	let coefficient = denominator === 0 ? 0 : Math.sqrt(Math.max(0, numerator / denominator));
	if (largeArc === sweep) { coefficient = -coefficient; }
	const cxp = coefficient * rx * y1p / ry;
	const cyp = -coefficient * ry * x1p / rx;
	const cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2;
	const cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2;
	const ux = (x1p - cxp) / rx;
	const uy = (y1p - cyp) / ry;
	const vx = (-x1p - cxp) / rx;
	const vy = (-y1p - cyp) / ry;
	const theta1 = vectorAngle(1, 0, ux, uy);
	let delta = vectorAngle(ux, uy, vx, vy);
	if (!sweep && delta > 0) { delta -= 2 * Math.PI; }
	if (sweep && delta < 0) { delta += 2 * Math.PI; }
	const segments = Math.max(1, Math.ceil(Math.abs(delta) / (Math.PI / 2) - 1e-9)) as int32;
	const step = delta / (segments as float64);
	const handle = 4.0 / 3.0 * Math.tan(step / 4);
	for (let i = 0; i < segments; i += 1) {
		const a1 = theta1 + step * (i as float64);
		const a2 = a1 + step;
		const cos1 = Math.cos(a1);
		const sin1 = Math.sin(a1);
		const cos2 = Math.cos(a2);
		const sin2 = Math.sin(a2);
		const e1x = cos1 - handle * sin1;
		const e1y = sin1 + handle * cos1;
		const e2x = cos2 + handle * sin2;
		const e2y = sin2 - handle * cos2;
		let endX = cx + rx * cosPhi * cos2 - ry * sinPhi * sin2;
		let endY = cy + rx * sinPhi * cos2 + ry * cosPhi * sin2;
		if (i === segments - 1) {
			endX = x2;
			endY = y2;
		}
		cubicTo(
			g,
			cx + rx * cosPhi * e1x - ry * sinPhi * e1y,
			cy + rx * sinPhi * e1x + ry * cosPhi * e1y,
			cx + rx * cosPhi * e2x - ry * sinPhi * e2y,
			cy + rx * sinPhi * e2x + ry * cosPhi * e2y,
			endX,
			endY,
		);
	}
}

function lowerCase(code: int32): int32 {
	return code >= 65 && code <= 90 ? code + 32 : code;
}

function runCommand(g: Geometry, ref c: PathCursor, ref pen: PenState, command: int32): boolean {
	const relative = command >= 97;
	const kind = lowerCase(command);
	if (kind === 122) {
		closePath(g);
		pen.x = pen.startX;
		pen.y = pen.startY;
		pen.lastCubic = false;
		pen.lastQuad = false;
		return true;
	}
	let first = true;
	while (first || startsNumber(c)) {
		const baseX = relative ? pen.x : 0;
		const baseY = relative ? pen.y : 0;
		let cubic = false;
		let quad = false;
		if (kind === 109 || kind === 108 || kind === 116) {
			const x = readNumber(c);
			if (!x.ok) { return false; }
			const y = readNumber(c);
			if (!y.ok) { return false; }
			const px = baseX + x.value;
			const py = baseY + y.value;
			if (kind === 109 && first) {
				moveTo(g, px, py);
				pen.startX = px;
				pen.startY = py;
			} else if (kind === 116) {
				const qx = pen.lastQuad ? 2 * pen.x - pen.controlX : pen.x;
				const qy = pen.lastQuad ? 2 * pen.y - pen.controlY : pen.y;
				quadTo(g, qx, qy, px, py);
				pen.controlX = qx;
				pen.controlY = qy;
				quad = true;
			} else {
				lineTo(g, px, py);
			}
			pen.x = px;
			pen.y = py;
		} else if (kind === 104) {
			const x = readNumber(c);
			if (!x.ok) { return false; }
			pen.x = baseX + x.value;
			lineTo(g, pen.x, pen.y);
		} else if (kind === 118) {
			const y = readNumber(c);
			if (!y.ok) { return false; }
			pen.y = baseY + y.value;
			lineTo(g, pen.x, pen.y);
		} else if (kind === 99 || kind === 115) {
			let x1 = 2 * pen.x - pen.controlX;
			let y1 = 2 * pen.y - pen.controlY;
			if (kind === 99) {
				const a = readNumber(c);
				if (!a.ok) { return false; }
				const b = readNumber(c);
				if (!b.ok) { return false; }
				x1 = baseX + a.value;
				y1 = baseY + b.value;
			} else if (!pen.lastCubic) {
				x1 = pen.x;
				y1 = pen.y;
			}
			const c2 = readNumber(c);
			if (!c2.ok) { return false; }
			const d2 = readNumber(c);
			if (!d2.ok) { return false; }
			const ex = readNumber(c);
			if (!ex.ok) { return false; }
			const ey = readNumber(c);
			if (!ey.ok) { return false; }
			const x2 = baseX + c2.value;
			const y2 = baseY + d2.value;
			cubicTo(g, x1, y1, x2, y2, baseX + ex.value, baseY + ey.value);
			pen.controlX = x2;
			pen.controlY = y2;
			pen.x = baseX + ex.value;
			pen.y = baseY + ey.value;
			cubic = true;
		} else if (kind === 113) {
			const a = readNumber(c);
			if (!a.ok) { return false; }
			const b = readNumber(c);
			if (!b.ok) { return false; }
			const ex = readNumber(c);
			if (!ex.ok) { return false; }
			const ey = readNumber(c);
			if (!ey.ok) { return false; }
			const qx = baseX + a.value;
			const qy = baseY + b.value;
			quadTo(g, qx, qy, baseX + ex.value, baseY + ey.value);
			pen.controlX = qx;
			pen.controlY = qy;
			pen.x = baseX + ex.value;
			pen.y = baseY + ey.value;
			quad = true;
		} else if (kind === 97) {
			const rx = readNumber(c);
			if (!rx.ok) { return false; }
			const ry = readNumber(c);
			if (!ry.ok) { return false; }
			const rotation = readNumber(c);
			if (!rotation.ok) { return false; }
			const large = readFlag(c);
			if (!large.ok) { return false; }
			const sweep = readFlag(c);
			if (!sweep.ok) { return false; }
			const ex = readNumber(c);
			if (!ex.ok) { return false; }
			const ey = readNumber(c);
			if (!ey.ok) { return false; }
			const tx = baseX + ex.value;
			const ty = baseY + ey.value;
			arcTo(g, pen.x, pen.y, rx.value, ry.value, rotation.value, large.value, sweep.value, tx, ty);
			pen.x = tx;
			pen.y = ty;
		} else {
			return false;
		}
		pen.lastCubic = cubic;
		pen.lastQuad = quad;
		first = false;
	}
	return true;
}

function isCommand(code: int32): boolean {
	const k = lowerCase(code);
	return k === 109 || k === 122 || k === 108 || k === 104 || k === 118 || k === 99 || k === 115 || k === 113 || k === 116 || k === 97;
}

export function parsePathData(d: string): Geometry {
	const g = emptyGeometry();
	let c: PathCursor = { text: d, at: 0 };
	let pen: PenState = { x: 0, y: 0, startX: 0, startY: 0, controlX: 0, controlY: 0, lastCubic: false, lastQuad: false };
	skipSpace(c);
	let started = false;
	while (c.at < c.text.length) {
		const command = c.text.charCodeAt(c.at);
		if (!isCommand(command)) { break; }
		// A path starts with a moveto; anything else is an error at the first command.
		if (!started && lowerCase(command) !== 109) { break; }
		started = true;
		c.at += 1;
		skipSpace(c);
		if (!runCommand(g, c, pen, command)) { break; }
		skipSpace(c);
	}
	return g;
}

export function geometryText(g: Geometry): string {
	let out = "";
	let i = 0;
	while (i < g.data.length) {
		const op = g.data[i] as int32 as PathOp;
		const letter = match (op) {
			PathOp.Move => "M",
			PathOp.Line => "L",
			PathOp.Cubic => "C",
			PathOp.Quad => "Q",
			PathOp.Close => "Z",
		};
		if (out !== "") { out += " "; }
		out += letter;
		const n = opArity(op);
		for (let k = 1; k <= n; k += 1) { out += " " + formatNumber(g.data[i + k]); }
		i += n + 1;
	}
	return out;
}

// Up to four decimals, no trailing zeros, no "-0": the same text on every backend.
export function formatNumber(v: float64): string {
	if (!(v === v)) { return "0"; }
	const scaled = Math.round(Math.abs(v) * 10000);
	if (scaled === 0) { return "0"; }
	if (scaled > 1e15) { return (v < 0 ? "-" : "") + Math.round(Math.abs(v)).toString(); }
	const whole = Math.floor(scaled / 10000);
	let fraction = (scaled - whole * 10000) as int32;
	let text = (v < 0 ? "-" : "") + (whole as int64).toString();
	if (fraction === 0) { return text; }
	let digits = "";
	let place = 1000;
	while (fraction > 0) {
		const digit = (fraction / place) as int32;
		digits += digit.toString();
		fraction -= digit * place;
		place = (place / 10) as int32;
	}
	return text + "." + digits;
}

export struct Bounds {
	minX: float64;
	minY: float64;
	maxX: float64;
	maxY: float64;
	empty: boolean;
}

export function emptyBounds(): Bounds {
	return { minX: 0, minY: 0, maxX: 0, maxY: 0, empty: true };
}

function include(ref b: Bounds, x: float64, y: float64): void {
	if (b.empty) {
		b.minX = x;
		b.maxX = x;
		b.minY = y;
		b.maxY = y;
		b.empty = false;
		return;
	}
	b.minX = Math.min(b.minX, x);
	b.maxX = Math.max(b.maxX, x);
	b.minY = Math.min(b.minY, y);
	b.maxY = Math.max(b.maxY, y);
}

function cubicPoint(p0: float64, p1: float64, p2: float64, p3: float64, t: float64): float64 {
	const u = 1 - t;
	return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
}

function cubicExtrema(p0: float64, p1: float64, p2: float64, p3: float64): float64[] {
	const a = -p0 + 3 * p1 - 3 * p2 + p3;
	const b = 2 * (p0 - 2 * p1 + p2);
	const c = p1 - p0;
	const found: float64[] = [];
	if (Math.abs(a) < 1e-12) {
		if (Math.abs(b) > 1e-12) { found.push(-c / b); }
	} else {
		const disc = b * b - 4 * a * c;
		if (disc >= 0) {
			const root = Math.sqrt(disc);
			found.push((-b + root) / (2 * a));
			found.push((-b - root) / (2 * a));
		}
	}
	const inside: float64[] = [];
	for (const t of found) {
		if (t > 0 && t < 1) { inside.push(t); }
	}
	return inside;
}

// The exact bounding box of the geometry (the objectBoundingBox of SVG 1.1 §7.11).
export function geometryBounds(g: Geometry): Bounds {
	let b = emptyBounds();
	let x = 0.0;
	let y = 0.0;
	let i = 0;
	while (i < g.data.length) {
		const op = g.data[i] as int32 as PathOp;
		const d = g.data;
		if (op === PathOp.Move || op === PathOp.Line) {
			x = d[i + 1];
			y = d[i + 2];
			include(b, x, y);
		} else if (op === PathOp.Cubic) {
			for (const t of cubicExtrema(x, d[i + 1], d[i + 3], d[i + 5])) {
				include(b, cubicPoint(x, d[i + 1], d[i + 3], d[i + 5], t), cubicPoint(y, d[i + 2], d[i + 4], d[i + 6], t));
			}
			for (const t of cubicExtrema(y, d[i + 2], d[i + 4], d[i + 6])) {
				include(b, cubicPoint(x, d[i + 1], d[i + 3], d[i + 5], t), cubicPoint(y, d[i + 2], d[i + 4], d[i + 6], t));
			}
			x = d[i + 5];
			y = d[i + 6];
			include(b, x, y);
		} else if (op === PathOp.Quad) {
			// A quadratic is the cubic with control points two thirds of the way to its control.
			const c1x = x + 2.0 / 3.0 * (d[i + 1] - x);
			const c1y = y + 2.0 / 3.0 * (d[i + 2] - y);
			const c2x = d[i + 3] + 2.0 / 3.0 * (d[i + 1] - d[i + 3]);
			const c2y = d[i + 4] + 2.0 / 3.0 * (d[i + 2] - d[i + 4]);
			for (const t of cubicExtrema(x, c1x, c2x, d[i + 3])) {
				include(b, cubicPoint(x, c1x, c2x, d[i + 3], t), cubicPoint(y, c1y, c2y, d[i + 4], t));
			}
			for (const t of cubicExtrema(y, c1y, c2y, d[i + 4])) {
				include(b, cubicPoint(x, c1x, c2x, d[i + 3], t), cubicPoint(y, c1y, c2y, d[i + 4], t));
			}
			x = d[i + 3];
			y = d[i + 4];
			include(b, x, y);
		}
		i += opArity(op) + 1;
	}
	return b;
}
