// The children of one <Svg> mount into a scene: a private Host whose nodes stay in
// MetaScript. Any change to it (a reactive prop, a <Show>, a <For> row) re-encodes the
// scene into one display list, which the real host receives as the `displayList` attr
// of its single `svg` node. Every platform draws that list (src/platform/*; the grammar
// is at `encodeScene`), so geometry is computed once, here, the same for all of them.

import { Host, HostNode } from "../../render/hostTypes";
import { Style, StyleValue } from "../../render/style";
import { NeonEvent } from "../../render/event";
import {
	Geometry,
	PathOp,
	Bounds,
	arcTo,
	closePath,
	emptyGeometry,
	formatNumber,
	geometryBounds,
	lineTo,
	moveTo,
	opArity,
	parsePathData,
} from "./pathData";
import { Rgba, parseColor } from "./color";

export class SvgNode {
	tag: string;
	text: string = "";
	isText: boolean = false;
	attrs: Map<string, string> = new Map<string, string>();
	children: SvgNode[] = [];
	parent: SvgNode | null = null;
	geometry: Geometry | null = null;

	constructor(tag: string) {
		this.tag = tag;
	}
}

export function attrOf(n: SvgNode, name: string): string {
	return n.attrs.has(name) ? n.attrs.get(name) as string : "";
}

export class SvgScene {
	root: SvgNode = new SvgNode("svg");
	listener: (() => void) | null = null;
	held: int32 = 0;
	pending: boolean = false;
}

export function sceneChanged(scene: SvgScene): void {
	if (scene.held > 0) {
		scene.pending = true;
		return;
	}
	const l = scene.listener;
	if (l !== null) { l(); }
}

export function holdScene(scene: SvgScene, fn: () => void): void {
	scene.held += 1;
	try {
		fn();
	} finally {
		scene.held -= 1;
	}
	if (scene.held === 0 && scene.pending) {
		scene.pending = false;
		sceneChanged(scene);
	}
}

function indexIn(parent: SvgNode, child: SvgNode): int32 {
	for (let i = 0; i < parent.children.length; i += 1) {
		if (parent.children[i] === child) { return i; }
	}
	return -1;
}

function detachNode(n: SvgNode): void {
	const p = n.parent;
	if (p === null) { return; }
	const at = indexIn(p as SvgNode, n);
	if (at >= 0) { (p as SvgNode).children.splice(at, 1); }
	n.parent = null;
}

function asNode(h: HostNode): SvgNode {
	return h as unknown as SvgNode;
}

export function sceneHost(scene: SvgScene): Host {
	return {
		createElement: (tag: string): HostNode => new SvgNode(tag) as unknown as HostNode,
		createText: (s: string): HostNode => {
			const n = new SvgNode("");
			n.isText = true;
			n.text = s;
			return n as unknown as HostNode;
		},
		setText: (node: HostNode, s: string): void => {
			asNode(node).text = s;
			sceneChanged(scene);
		},
		setAttr: (node: HostNode, name: string, value: string): void => {
			const n = asNode(node);
			n.attrs.set(name, value);
			n.geometry = null;
			sceneChanged(scene);
		},
		removeAttr: (node: HostNode, name: string): void => {
			const n = asNode(node);
			n.attrs.delete(name);
			n.geometry = null;
			sceneChanged(scene);
		},
		setStyle: (node: HostNode, style: Style): void => {},
		setStyleProp: null,
		setStyleClass: null,
		addEvent: (node: HostNode, name: string, handler: (e: NeonEvent) => void): void => {
			throw new Error(`<Svg>: shapes take no events yet (${name} on <${asNode(node).tag}>)`);
		},
		append: (parent: HostNode, child: HostNode): void => {
			const c = asNode(child);
			detachNode(c);
			c.parent = asNode(parent);
			asNode(parent).children.push(c);
			sceneChanged(scene);
		},
		insertBefore: (parent: HostNode, node: HostNode, ref: HostNode | null): void => {
			const p = asNode(parent);
			const n = asNode(node);
			if (ref === node) { return; }
			detachNode(n);
			let at: int32 = p.children.length as int32;
			if (ref !== null) {
				at = indexIn(p, asNode(ref as HostNode));
				if (at < 0) { throw new Error("insertBefore: the reference node is not a child of the parent"); }
			}
			n.parent = p;
			p.children.splice(at, 0, n);
			sceneChanged(scene);
		},
		removeChild: (parent: HostNode, node: HostNode): void => {
			const p = asNode(parent);
			const at = indexIn(p, asNode(node));
			if (at < 0) { throw new Error("removeChild: the node is not a child of the parent"); }
			p.children.splice(at, 1);
			asNode(node).parent = null;
			sceneChanged(scene);
		},
		parentOf: (node: HostNode): HostNode | null => {
			const p = asNode(node).parent;
			if (p === null) { return null; }
			return p as unknown as HostNode;
		},
		release: (node: HostNode): void => {
			if (asNode(node).parent !== null) { throw new Error("release: the node still has a parent; remove it first"); }
		},
		nextSibling: (node: HostNode): HostNode | null => {
			const n = asNode(node);
			const p = n.parent;
			if (p === null) { return null; }
			const at = indexIn(p as SvgNode, n);
			if (at < 0 || at + 1 >= (p as SvgNode).children.length) { return null; }
			return (p as SvgNode).children[at + 1] as unknown as HostNode;
		},
		firstChild: (node: HostNode): HostNode | null => {
			const n = asNode(node);
			return n.children.length === 0 ? null : n.children[0] as unknown as HostNode;
		},
		cloneNode: null,
		voidArea: null,
		scrollTo: null,
		measureText: null,
	};
}


export struct Affine {
	a: float64;
	b: float64;
	c: float64;
	d: float64;
	e: float64;
	f: float64;
}

export function identity(): Affine {
	return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 };
}

export function multiply(m: Affine, n: Affine): Affine {
	return {
		a: m.a * n.a + m.c * n.b,
		b: m.b * n.a + m.d * n.b,
		c: m.a * n.c + m.c * n.d,
		d: m.b * n.c + m.d * n.d,
		e: m.a * n.e + m.c * n.f + m.e,
		f: m.b * n.e + m.d * n.f + m.f,
	};
}

function translation(x: float64, y: float64): Affine {
	return { a: 1, b: 0, c: 0, d: 1, e: x, f: y };
}

function rotationAbout(degrees: float64, x: float64, y: float64): Affine {
	const r = degrees * Math.PI / 180;
	const turn: Affine = { a: Math.cos(r), b: Math.sin(r), c: -Math.sin(r), d: Math.cos(r), e: 0, f: 0 };
	return multiply(translation(x, y), multiply(turn, translation(-x, -y)));
}

export function lengthValue(text: string, fallback: float64, reference: float64): float64 {
	const t = text.trim();
	if (t === "") { return fallback; }
	if (t.endsWith("%")) {
		const p: float64 = parseFloat(t.substring(0, t.length - 1));
		return p === p ? p * reference / 100 : fallback;
	}
	const plain = t.endsWith("px") ? t.substring(0, t.length - 2) : t;
	const v: float64 = parseFloat(plain);
	return v === v ? v : fallback;
}

export function numberList(text: string): float64[] {
	const out: float64[] = [];
	const parts: string[] = text.split(",").join(" ").split(" ");
	for (const p of parts) {
		if (p.trim() === "") { continue; }
		const v: float64 = parseFloat(p.trim());
		if (!(v === v)) { break; }
		out.push(v);
	}
	return out;
}

export function parseTransform(text: string): Affine {
	let m = identity();
	let rest = text;
	while (true) {
		const open = rest.indexOf("(");
		const close = rest.indexOf(")");
		if (open < 0 || close < open) { break; }
		const name = rest.substring(0, open).split(",").join(" ").trim();
		const args = numberList(rest.substring(open + 1, close));
		rest = rest.substring(close + 1, rest.length);
		let step = identity();
		if (name === "matrix" && args.length === 6) {
			step = { a: args[0], b: args[1], c: args[2], d: args[3], e: args[4], f: args[5] };
		} else if (name === "translate" && args.length >= 1) {
			step = translation(args[0], args.length > 1 ? args[1] : 0);
		} else if (name === "scale" && args.length >= 1) {
			step = { a: args[0], b: 0, c: 0, d: args.length > 1 ? args[1] : args[0], e: 0, f: 0 };
		} else if (name === "rotate" && args.length >= 1) {
			step = rotationAbout(args[0], args.length >= 3 ? args[1] : 0, args.length >= 3 ? args[2] : 0);
		} else if (name === "skewX" && args.length === 1) {
			step = { a: 1, b: 0, c: Math.tan(args[0] * Math.PI / 180), d: 1, e: 0, f: 0 };
		} else if (name === "skewY" && args.length === 1) {
			step = { a: 1, b: Math.tan(args[0] * Math.PI / 180), c: 0, d: 1, e: 0, f: 0 };
		} else {
			throw new Error(`<Svg>: unsupported transform "${text}"`);
		}
		m = multiply(m, step);
	}
	return m;
}

// react-native-svg's transform props (translate, rotation, scale about an origin), then
// the `transform` list.
export function nodeTransform(n: SvgNode): Affine {
	let m = identity();
	const rotation = lengthValue(attrOf(n, "rotation"), 0, 0);
	const scale = attrOf(n, "scale");
	const tx = lengthValue(attrOf(n, "translateX"), 0, 0);
	const ty = lengthValue(attrOf(n, "translateY"), 0, 0);
	if (rotation !== 0 || scale !== "" || tx !== 0 || ty !== 0) {
		const ox = lengthValue(attrOf(n, "originX"), 0, 0);
		const oy = lengthValue(attrOf(n, "originY"), 0, 0);
		const s = lengthValue(scale, 1, 0);
		m = multiply(translation(tx + ox, ty + oy), multiply(rotationAbout(rotation, 0, 0), { a: s, b: 0, c: 0, d: s, e: -ox * s, f: -oy * s }));
	}
	const list = attrOf(n, "transform");
	if (list !== "") { m = multiply(m, parseTransform(list)); }
	return m;
}

export function transformGeometry(g: Geometry, m: Affine): Geometry {
	const out = emptyGeometry();
	let i = 0;
	while (i < g.data.length) {
		const op = g.data[i] as int32 as PathOp;
		out.data.push(g.data[i]);
		const n = opArity(op);
		for (let k = 1; k < n; k += 2) {
			const x = g.data[i + k];
			const y = g.data[i + k + 1];
			out.data.push(m.a * x + m.c * y + m.e);
			out.data.push(m.b * x + m.d * y + m.f);
		}
		i += n + 1;
	}
	return out;
}


export struct Viewport {
	width: float64;
	height: float64;
}

function diagonal(v: Viewport): float64 {
	return Math.sqrt((v.width * v.width + v.height * v.height) / 2);
}

function lenX(n: SvgNode, name: string, v: Viewport): float64 {
	return lengthValue(attrOf(n, name), 0, v.width);
}

function lenY(n: SvgNode, name: string, v: Viewport): float64 {
	return lengthValue(attrOf(n, name), 0, v.height);
}

function ellipseGeometry(g: Geometry, cx: float64, cy: float64, rx: float64, ry: float64): void {
	if (rx <= 0 || ry <= 0) { return; }
	moveTo(g, cx + rx, cy);
	arcTo(g, cx + rx, cy, rx, ry, 0, false, true, cx, cy + ry);
	arcTo(g, cx, cy + ry, rx, ry, 0, false, true, cx - rx, cy);
	arcTo(g, cx - rx, cy, rx, ry, 0, false, true, cx, cy - ry);
	arcTo(g, cx, cy - ry, rx, ry, 0, false, true, cx + rx, cy);
	closePath(g);
}

// SVG 2 §10.2: a rect with rounded corners is a path of four arcs.
function rectGeometry(g: Geometry, n: SvgNode, v: Viewport): void {
	const x = lenX(n, "x", v);
	const y = lenY(n, "y", v);
	const w = lenX(n, "width", v);
	const h = lenY(n, "height", v);
	if (w <= 0 || h <= 0) { return; }
	const hasRx = attrOf(n, "rx") !== "";
	const hasRy = attrOf(n, "ry") !== "";
	let rx = lenX(n, "rx", v);
	let ry = lenY(n, "ry", v);
	if (!hasRx) { rx = ry; }
	if (!hasRy) { ry = rx; }
	rx = Math.min(Math.max(rx, 0), w / 2);
	ry = Math.min(Math.max(ry, 0), h / 2);
	if (rx === 0 || ry === 0) {
		moveTo(g, x, y);
		lineTo(g, x + w, y);
		lineTo(g, x + w, y + h);
		lineTo(g, x, y + h);
		closePath(g);
		return;
	}
	moveTo(g, x + rx, y);
	lineTo(g, x + w - rx, y);
	arcTo(g, x + w - rx, y, rx, ry, 0, false, true, x + w, y + ry);
	lineTo(g, x + w, y + h - ry);
	arcTo(g, x + w, y + h - ry, rx, ry, 0, false, true, x + w - rx, y + h);
	lineTo(g, x + rx, y + h);
	arcTo(g, x + rx, y + h, rx, ry, 0, false, true, x, y + h - ry);
	lineTo(g, x, y + ry);
	arcTo(g, x, y + ry, rx, ry, 0, false, true, x + rx, y);
	closePath(g);
}

function pointsGeometry(g: Geometry, text: string, close: boolean): void {
	const values = numberList(text);
	const pairs = (values.length / 2) as int32;
	for (let i = 0; i < pairs; i += 1) {
		if (i === 0) { moveTo(g, values[0], values[1]); } else { lineTo(g, values[2 * i], values[2 * i + 1]); }
	}
	if (close && pairs > 0) { closePath(g); }
}

export function isShape(tag: string): boolean {
	return tag === "path" || tag === "rect" || tag === "circle" || tag === "ellipse" || tag === "line" || tag === "polyline" || tag === "polygon";
}

export function shapeGeometry(n: SvgNode, v: Viewport): Geometry {
	const cached = n.geometry;
	if (cached !== null) { return cached as Geometry; }
	let g = emptyGeometry();
	const tag = n.tag;
	if (tag === "path") {
		g = parsePathData(attrOf(n, "d"));
	} else if (tag === "rect") {
		rectGeometry(g, n, v);
	} else if (tag === "circle") {
		const r = lengthValue(attrOf(n, "r"), 0, diagonal(v));
		ellipseGeometry(g, lenX(n, "cx", v), lenY(n, "cy", v), r, r);
	} else if (tag === "ellipse") {
		ellipseGeometry(g, lenX(n, "cx", v), lenY(n, "cy", v), lenX(n, "rx", v), lenY(n, "ry", v));
	} else if (tag === "line") {
		moveTo(g, lenX(n, "x1", v), lenY(n, "y1", v));
		lineTo(g, lenX(n, "x2", v), lenY(n, "y2", v));
	} else if (tag === "polyline" || tag === "polygon") {
		pointsGeometry(g, attrOf(n, "points"), tag === "polygon");
	}
	n.geometry = g;
	return g;
}


struct Presentation {
	fill: string;
	fillOpacity: float64;
	fillRule: string;
	stroke: string;
	strokeWidth: string;
	strokeOpacity: float64;
	linecap: string;
	linejoin: string;
	miterlimit: float64;
	dasharray: string;
	dashoffset: string;
	fontSize: string;
	fontWeight: string;
	textAnchor: string;
	color: string;
}

function initialPresentation(): Presentation {
	return {
		fill: "black",
		fillOpacity: 1,
		fillRule: "nonzero",
		stroke: "none",
		strokeWidth: "1",
		strokeOpacity: 1,
		linecap: "butt",
		linejoin: "miter",
		miterlimit: 4,
		dasharray: "none",
		dashoffset: "0",
		fontSize: "12",
		fontWeight: "normal",
		textAnchor: "start",
		color: "black",
	};
}

function pick(n: SvgNode, name: string, inherited: string): string {
	const own = attrOf(n, name);
	return own === "" || own === "inherit" ? inherited : own;
}

function unit(text: string, inherited: float64): float64 {
	if (text === "") { return inherited; }
	return Math.min(Math.max(lengthValue(text, inherited, 1), 0), 1);
}

function inherit(n: SvgNode, p: Presentation): Presentation {
	return {
		fill: pick(n, "fill", p.fill),
		fillOpacity: unit(attrOf(n, "fillOpacity"), p.fillOpacity),
		fillRule: pick(n, "fillRule", p.fillRule),
		stroke: pick(n, "stroke", p.stroke),
		strokeWidth: pick(n, "strokeWidth", p.strokeWidth),
		strokeOpacity: unit(attrOf(n, "strokeOpacity"), p.strokeOpacity),
		linecap: pick(n, "strokeLinecap", p.linecap),
		linejoin: pick(n, "strokeLinejoin", p.linejoin),
		miterlimit: lengthValue(attrOf(n, "strokeMiterlimit"), p.miterlimit, 0),
		dasharray: pick(n, "strokeDasharray", p.dasharray),
		dashoffset: pick(n, "strokeDashoffset", p.dashoffset),
		fontSize: pick(n, "fontSize", p.fontSize),
		fontWeight: pick(n, "fontWeight", p.fontWeight),
		textAnchor: pick(n, "textAnchor", p.textAnchor),
		color: pick(n, "color", p.color),
	};
}

function capCode(text: string): int32 {
	return match (text) {
		"round" => 1,
		"square" => 2,
		_ => 0,
	};
}

function joinCode(text: string): int32 {
	return match (text) {
		"round" => 1,
		"bevel" => 2,
		_ => 0,
	};
}

function alignCode(text: string): int32 {
	return match (text) {
		"none" => 0,
		"xMinYMin" => 1,
		"xMidYMin" => 2,
		"xMaxYMin" => 3,
		"xMinYMid" => 4,
		"xMaxYMid" => 6,
		"xMinYMax" => 7,
		"xMidYMax" => 8,
		"xMaxYMax" => 9,
		_ => 5,
	};
}

export function escapeText(s: string): string {
	return s.split("%").join("%25").split(" ").join("%20").split("+").join("%2B").split("\n").join("%0A").split("\t").join("%09");
}

export function unescapeText(s: string): string {
	return s.split("%09").join("\t").split("%0A").join("\n").split("%2B").join("+").split("%20").join(" ").split("%25").join("%");
}

function collapseSpace(s: string): string {
	let out = "";
	let space = false;
	for (let i = 0; i < s.length; i += 1) {
		const code = s.charCodeAt(i);
		if (code === 32 || code === 9 || code === 10 || code === 13) {
			space = true;
			continue;
		}
		if (space && out !== "") { out += " "; }
		space = false;
		out += s.substring(i, i + 1);
	}
	if (space && out !== "") { out += " "; }
	return out;
}

function textContent(n: SvgNode): string {
	if (n.isText) { return n.text; }
	let s = "";
	for (const c of n.children) { s += textContent(c); }
	return s;
}

export function urlTarget(value: string): string {
	const t = value.trim();
	if (!t.startsWith("url(")) { return ""; }
	const close = t.indexOf(")");
	if (close < 0) { return ""; }
	const inner = t.substring(4, close).trim();
	return inner.startsWith("#") ? inner.substring(1, inner.length) : inner;
}

function urlFallback(value: string): string {
	const close = value.indexOf(")");
	return close < 0 ? "" : value.substring(close + 1, value.length).trim();
}


class Encoder {
	out: string = "";
	ids: Map<string, SvgNode> = new Map<string, SvgNode>();
	viewport: Viewport = { width: 0, height: 0 };
	lastMatrix: string = "";
	useDepth: int32 = 0;

	op(text: string): void {
		if (this.out !== "") { this.out += " "; }
		this.out += text;
	}

	num(v: float64): void {
		this.op(formatNumber(v));
	}

	matrix(m: Affine): void {
		const text = "X " + formatNumber(m.a) + " " + formatNumber(m.b) + " " + formatNumber(m.c) + " " +
			formatNumber(m.d) + " " + formatNumber(m.e) + " " + formatNumber(m.f);
		if (text === this.lastMatrix) { return; }
		this.lastMatrix = text;
		this.op(text);
	}

	geometry(g: Geometry): void {
		let i = 0;
		while (i < g.data.length) {
			const op = g.data[i] as int32 as PathOp;
			this.op(match (op) {
				PathOp.Move => "M",
				PathOp.Line => "L",
				PathOp.Cubic => "C",
				PathOp.Quad => "Q",
				PathOp.Close => "Z",
			});
			const n = opArity(op);
			for (let k = 1; k <= n; k += 1) { this.num(g.data[i + k]); }
			i += n + 1;
		}
	}

	collectIds(n: SvgNode): void {
		const id = attrOf(n, "id");
		if (id !== "" && !this.ids.has(id)) { this.ids.set(id, n); }
		for (const c of n.children) { this.collectIds(c); }
	}

	resolveColor(text: string, p: Presentation): Rgba | null {
		const t = text.trim();
		if (t === "" || t === "none") { return null; }
		const r = parseColor(t === "currentColor" ? p.color : t);
		if (!r.ok) { throw new Error(`<Svg>: unknown colour "${t}"`); }
		return r.value;
	}

	colorTokens(c: Rgba, alpha: float64): string {
		return `${c.r} ${c.g} ${c.b} ${formatNumber(c.a * alpha)}`;
	}

	gradientStops(gradient: SvgNode, alpha: float64, p: Presentation): string[] {
		const stops: string[] = [];
		let last = 0.0;
		for (const s of gradient.children) {
			if (s.tag !== "stop") { continue; }
			let offset = Math.min(Math.max(lengthValue(attrOf(s, "offset"), 0, 1), 0), 1);
			offset = Math.max(offset, last);
			last = offset;
			const colorText = attrOf(s, "stopColor");
			let c = this.resolveColor(colorText === "" ? "black" : colorText, p);
			if (c === null) { c = { r: 0, g: 0, b: 0, a: 0.0 }; }
			const stopAlpha = unit(attrOf(s, "stopOpacity"), 1);
			stops.push(formatNumber(offset) + " " + this.colorTokens(c as Rgba, alpha * stopAlpha));
		}
		return stops;
	}

	// A paint as display-list tokens: n, c r g b a, or a gradient (l / r).
	paint(value: string, alpha: float64, p: Presentation, bounds: Bounds): string {
		const target = urlTarget(value);
		if (target === "") {
			const c = this.resolveColor(value, p);
			return c === null ? "n" : "c " + this.colorTokens(c as Rgba, alpha);
		}
		if (!this.ids.has(target)) {
			const fallback = urlFallback(value);
			return fallback === "" ? "n" : this.paint(fallback, alpha, p, bounds);
		}
		const g = this.ids.get(target) as SvgNode;
		const linear = g.tag === "lineargradient";
		if (!linear && g.tag !== "radialgradient") { return "n"; }
		const stops = this.gradientStops(g, alpha, p);
		if (stops.length === 0) { return "n"; }
		if (stops.length === 1) {
			const one: string[] = stops[0].split(" ");
			return `c ${one[1]} ${one[2]} ${one[3]} ${one[4]}`;
		}
		const userSpace = attrOf(g, "gradientUnits") === "userSpaceOnUse";
		let m = identity();
		let refX = 1.0;
		let refY = 1.0;
		if (userSpace) {
			refX = this.viewport.width;
			refY = this.viewport.height;
		} else {
			if (bounds.empty || bounds.maxX - bounds.minX <= 0 || bounds.maxY - bounds.minY <= 0) { return "n"; }
			m = { a: bounds.maxX - bounds.minX, b: 0, c: 0, d: bounds.maxY - bounds.minY, e: bounds.minX, f: bounds.minY };
		}
		const gt = attrOf(g, "gradientTransform");
		if (gt !== "") { m = multiply(m, parseTransform(gt)); }
		let text = (linear ? "l " : "r ") + formatNumber(m.a) + " " + formatNumber(m.b) + " " + formatNumber(m.c) + " " +
			formatNumber(m.d) + " " + formatNumber(m.e) + " " + formatNumber(m.f);
		if (linear) {
			text += " " + formatNumber(lengthValue(attrOf(g, "x1"), 0, refX)) + " " + formatNumber(lengthValue(attrOf(g, "y1"), 0, refY));
			text += " " + formatNumber(lengthValue(attrOf(g, "x2"), refX, refX)) + " " + formatNumber(lengthValue(attrOf(g, "y2"), 0, refY));
		} else {
			const cx = lengthValue(attrOf(g, "cx"), refX / 2, refX);
			const cy = lengthValue(attrOf(g, "cy"), refY / 2, refY);
			const diag = userSpace ? diagonal(this.viewport) : 1.0;
			text += " " + formatNumber(cx) + " " + formatNumber(cy) + " " + formatNumber(lengthValue(attrOf(g, "r"), diag / 2, diag));
			text += " " + formatNumber(lengthValue(attrOf(g, "fx"), cx, refX)) + " " + formatNumber(lengthValue(attrOf(g, "fy"), cy, refY));
		}
		text += " " + stops.length.toString();
		for (const s of stops) { text += " " + s; }
		return text;
	}

	firstStopColor(value: string, alpha: float64, p: Presentation): string {
		const paint = this.paint(value, alpha, p, { minX: 0, minY: 0, maxX: 1, maxY: 1, empty: false });
		if (paint === "n" || paint.startsWith("c ")) { return paint; }
		const tokens: string[] = paint.split(" ");
		const firstStop = paint.startsWith("l ") ? 12 : 13;
		return `c ${tokens[firstStop + 1]} ${tokens[firstStop + 2]} ${tokens[firstStop + 3]} ${tokens[firstStop + 4]}`;
	}

	dashTokens(p: Presentation): string {
		if (p.dasharray === "none") { return "D 0 0"; }
		const ref = diagonal(this.viewport);
		const raw = numberList(p.dasharray);
		let sum = 0.0;
		for (const d of raw) {
			if (d < 0) { return "D 0 0"; }
			sum += d;
		}
		if (raw.length === 0 || sum <= 0) { return "D 0 0"; }
		const dashes: float64[] = [];
		for (const d of raw) { dashes.push(d); }
		if (raw.length % 2 === 1) { for (const d of raw) { dashes.push(d); } }
		let text = "D " + dashes.length.toString();
		for (const d of dashes) { text += " " + formatNumber(d); }
		return text + " " + formatNumber(lengthValue(p.dashoffset, 0, ref));
	}

	clipOpen(n: SvgNode, m: Affine): boolean {
		const target = urlTarget(attrOf(n, "clipPath"));
		if (target === "") { return false; }
		if (!this.ids.has(target) || (this.ids.get(target) as SvgNode).tag !== "clippath") { return false; }
		const clip = this.ids.get(target) as SvgNode;
		const merged = emptyGeometry();
		let rule = attrOf(clip, "clipRule");
		for (const c of clip.children) {
			if (!isShape(c.tag)) { continue; }
			const placed = transformGeometry(shapeGeometry(c, this.viewport), nodeTransform(c));
			for (const v of placed.data) { merged.data.push(v); }
			if (rule === "") { rule = attrOf(c, "clipRule"); }
		}
		this.matrix(multiply(m, nodeTransform(clip)));
		this.geometry(merged);
		this.op(rule === "evenodd" ? "E 1" : "E 0");
		this.op("K");
		return true;
	}

	shape(n: SvgNode, m: Affine, p: Presentation, opacity: float64): void {
		const g = shapeGeometry(n, this.viewport);
		if (g.data.length === 0) { return; }
		const bounds = geometryBounds(g);
		const fill = this.paint(p.fill, p.fillOpacity * opacity, p, bounds);
		const stroke = this.paint(p.stroke, p.strokeOpacity * opacity, p, bounds);
		const width = lengthValue(p.strokeWidth, 1, diagonal(this.viewport));
		if (fill === "n" && (stroke === "n" || width <= 0)) { return; }
		this.matrix(m);
		this.geometry(g);
		this.op("F " + fill);
		this.op(width > 0 ? "S " + stroke : "S n");
		this.op(p.fillRule === "evenodd" ? "E 1" : "E 0");
		if (stroke !== "n" && width > 0) {
			this.op(`W ${formatNumber(width)} ${capCode(p.linecap)} ${joinCode(p.linejoin)} ${formatNumber(p.miterlimit)}`);
			this.op(this.dashTokens(p));
		}
		this.op("O");
	}

	// A run positioned by `owner`; the first run of a text starts at the text's x and y
	// (`start`) unless it sets its own.
	run(owner: SvgNode, start: SvgNode | null, text: string, p: Presentation, opacity: float64): string {
		const ownX = attrOf(owner, "x") !== "";
		const ownY = attrOf(owner, "y") !== "";
		const hasX = ownX || start !== null;
		const hasY = ownY || start !== null;
		const x = ownX || start === null ? lenX(owner, "x", this.viewport) : lenX(start as SvgNode, "x", this.viewport);
		const y = ownY || start === null ? lenY(owner, "y", this.viewport) : lenY(start as SvgNode, "y", this.viewport);
		const dx = lenX(owner, "dx", this.viewport);
		const dy = lenY(owner, "dy", this.viewport);
		const size = lengthValue(p.fontSize, 12, 0);
		const weight = p.fontWeight;
		const bold = weight === "bold" || weight === "bolder" || (parseFloat(weight) as float64) >= 600;
		let color = this.firstStopColor(p.fill, p.fillOpacity * opacity, p);
		if (color === "n") { color = "c 0 0 0 0"; }
		return `${hasX ? 1 : 0} ${formatNumber(x)} ${hasY ? 1 : 0} ${formatNumber(y)} ${formatNumber(dx)} ${formatNumber(dy)} ` +
			`${formatNumber(size)} ${bold ? 1 : 0} ${color.substring(2, color.length)} ${escapeText(text)}`;
	}

	text(n: SvgNode, m: Affine, p: Presentation, opacity: float64): void {
		const runs: string[] = [];
		let pending = "";
		for (const c of n.children) {
			if (c.isText) {
				pending += c.text;
				continue;
			}
			if (c.tag !== "tspan") { continue; }
			if (pending !== "") {
				runs.push(this.run(runs.length === 0 ? n : new SvgNode("tspan"), runs.length === 0 ? n : null, collapseSpace(pending), p, opacity));
				pending = "";
			}
			const content = collapseSpace(textContent(c));
			if (content === "") { continue; }
			runs.push(this.run(c, runs.length === 0 ? n : null, content, inherit(c, p), opacity));
		}
		if (pending !== "") {
			runs.push(this.run(runs.length === 0 ? n : new SvgNode("tspan"), runs.length === 0 ? n : null, collapseSpace(pending), p, opacity));
		}
		if (runs.length === 0) { return; }
		this.matrix(m);
		const anchor = match (p.textAnchor) {
			"middle" => 1,
			"end" => 2,
			_ => 0,
		};
		let text = `T ${anchor} ${runs.length}`;
		for (const r of runs) { text += " " + r; }
		this.op(text);
	}

	node(n: SvgNode, outer: Affine, inherited: Presentation, inheritedOpacity: float64): void {
		if (n.isText) { return; }
		const tag = n.tag;
		if (tag === "defs" || tag === "lineargradient" || tag === "radialgradient" || tag === "stop" || tag === "clippath" || tag === "symbol") { return; }
		if (attrOf(n, "display") === "none") { return; }
		const p = inherit(n, inherited);
		let m = multiply(outer, nodeTransform(n));
		const opacity = unit(attrOf(n, "opacity"), 1);
		const clipped = this.clipOpen(n, m);
		if (tag === "g" || tag === "svg" || tag === "use") {
			const layer = opacity < 1;
			if (layer) { this.op("G " + formatNumber(opacity)); }
			if (tag === "use") {
				const href = attrOf(n, "href");
				const id = href.startsWith("#") ? href.substring(1, href.length) : href;
				if (this.ids.has(id)) {
					if (this.useDepth > 16) { throw new Error(`<Svg>: <Use href="${href}"> refers to itself`); }
					this.useDepth += 1;
					m = multiply(m, translation(lenX(n, "x", this.viewport), lenY(n, "y", this.viewport)));
					const target = this.ids.get(id) as SvgNode;
					if (target.tag === "symbol") {
						for (const c of target.children) { this.node(c, m, p, inheritedOpacity); }
					} else {
						this.node(target, m, p, inheritedOpacity);
					}
					this.useDepth -= 1;
				}
			} else {
				for (const c of n.children) { this.node(c, m, p, inheritedOpacity); }
			}
			if (layer) { this.op("g"); }
		} else if (isShape(tag)) {
			this.shape(n, m, p, opacity * inheritedOpacity);
		} else if (tag === "text") {
			this.text(n, m, p, opacity * inheritedOpacity);
		}
		if (clipped) { this.op("k"); }
	}
}

function viewBoxOf(root: SvgNode): float64[] {
	const box = numberList(attrOf(root, "viewBox"));
	return box.length === 4 && box[2] > 0 && box[3] > 0 ? box : [];
}

// The display list: space-separated tokens, numbers with up to four decimals.
//   V minX minY width height align slice   the viewBox, first when the Svg has one
//                                          (align 0 none, 1..9 xMinYMin..xMaxYMax; slice 0 meet, 1 slice)
//   X a b c d e f                          the matrix for what follows (user space to viewBox space)
//   M x y | L x y | C x1 y1 x2 y2 x y | Q x1 y1 x y | Z    the current path
//   F paint, S paint                       fill and stroke paint:
//       n                                  none
//       c r g b a                          a colour (0..255, alpha 0..1)
//       l a b c d e f x1 y1 x2 y2 k (offset r g b a)*k        linear gradient; the matrix maps
//       r a b c d e f cx cy r fx fy k (offset r g b a)*k      gradient space into user space
//   E rule                                 0 nonzero, 1 evenodd
//   W width cap join miterlimit            stroke geometry (cap 0 butt 1 round 2 square; join 0 miter 1 round 2 bevel)
//   D k dash*k offset                      dashes (k 0: solid)
//   O                                      fill then stroke the current path, then clear it
//   K / k                                  clip to the current path (in its matrix) until the matching k
//   G alpha / g                            draw what is between into a layer composited at alpha
//   T anchor k (hasX x hasY y dx dy size bold r g b a text)*k
//                                          text runs at a baseline; a run without x continues after the
//                                          previous one; anchor 0 start 1 middle 2 end per chunk; text is
//                                          escaped (% space + newline tab as %XX)
export function encodeScene(scene: SvgScene): string {
	const e = new Encoder();
	const root = scene.root;
	e.collectIds(root);
	const box = viewBoxOf(root);
	if (box.length === 4) {
		e.viewport = { width: box[2], height: box[3] };
		const aspect: string[] = attrOf(root, "preserveAspectRatio").trim().split(" ");
		const align = alignCode(aspect[0]);
		const slice = aspect.length > 1 && aspect[1] === "slice" ? 1 : 0;
		e.op(`V ${formatNumber(box[0])} ${formatNumber(box[1])} ${formatNumber(box[2])} ${formatNumber(box[3])} ${align} ${slice}`);
	} else {
		e.viewport = { width: lengthValue(attrOf(root, "width"), 0, 0), height: lengthValue(attrOf(root, "height"), 0, 0) };
	}
	e.lastMatrix = "X 1 0 0 1 0 0";
	e.node(root, identity(), initialPresentation(), 1);
	return e.out;
}
