// The display list (./scene.ms `encodeScene`) as SVG markup: what the browser host puts
// inside its <svg> element, so the browser draws the same geometry the natives draw.

import { unescapeText } from "./scene";

export interface SvgMarkup {
	viewBox: string;
	preserveAspectRatio: string;
	body: string;
}

function alignName(code: string): string {
	return match (code) {
		"0" => "none",
		"1" => "xMinYMin",
		"2" => "xMidYMin",
		"3" => "xMaxYMin",
		"4" => "xMinYMid",
		"6" => "xMaxYMid",
		"7" => "xMinYMax",
		"8" => "xMidYMax",
		"9" => "xMaxYMax",
		_ => "xMidYMid",
	};
}

function escapeXml(s: string): string {
	return s.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;").split("\"").join("&quot;");
}

function arity(op: string): int32 {
	return match (op) {
		"M" => 2,
		"L" => 2,
		"C" => 6,
		"Q" => 4,
		_ => 0,
	};
}

class MarkupWriter {
	tokens: string[];
	at: int32 = 0;
	prefix: string;
	ids: int32 = 0;
	body: string = "";
	defs: string = "";
	matrix: string = "";
	path: string = "";
	fill: string = "";
	stroke: string = "";
	rule: string = "0";
	strokeAttrs: string = "";

	constructor(list: string, prefix: string) {
		this.tokens = list === "" ? [] : list.split(" ");
		this.prefix = prefix;
	}

	next(): string {
		const t = this.tokens[this.at];
		this.at += 1;
		return t;
	}

	take(count: int32): string {
		let out = "";
		for (let i = 0; i < count; i += 1) {
			const t = this.next();
			out += (i === 0 ? "" : " ") + t;
		}
		return out;
	}

	nextId(kind: string): string {
		this.ids += 1;
		return `${this.prefix}-${kind}${this.ids}`;
	}

	color(): string {
		const rgb: string[] = this.take(3).split(" ");
		const a = this.next();
		return `rgb(${rgb[0]},${rgb[1]},${rgb[2]})\x1f${a}`;
	}

	stops(): string {
		const count = parseInt(this.next()) as int32;
		let out = "";
		for (let i = 0; i < count; i += 1) {
			const offset = this.next();
			const parts: string[] = this.color().split("\x1f");
			out += `<stop offset="${offset}" stop-color="${parts[0]}" stop-opacity="${parts[1]}"/>`;
		}
		return out;
	}

	paint(name: string): string {
		const kind = this.next();
		if (kind === "n") { return `${name}="none"`; }
		if (kind === "c") {
			const parts: string[] = this.color().split("\x1f");
			return `${name}="${parts[0]}" ${name}-opacity="${parts[1]}"`;
		}
		const m = `matrix(${this.take(6)})`;
		const id = this.nextId("g");
		if (kind === "l") {
			const v: string[] = this.take(4).split(" ");
			const coords = `x1="${v[0]}" y1="${v[1]}" x2="${v[2]}" y2="${v[3]}"`;
			this.defs += `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" gradientTransform="${m}" ${coords}>${this.stops()}</linearGradient>`;
		} else {
			const v: string[] = this.take(5).split(" ");
			const coords = `cx="${v[0]}" cy="${v[1]}" r="${v[2]}" fx="${v[3]}" fy="${v[4]}"`;
			this.defs += `<radialGradient id="${id}" gradientUnits="userSpaceOnUse" gradientTransform="${m}" ${coords}>${this.stops()}</radialGradient>`;
		}
		return `${name}="url(#${id})"`;
	}

	transformAttr(): string {
		return this.matrix === "" ? "" : ` transform="matrix(${this.matrix})"`;
	}

	textRuns(): void {
		const anchor = match (this.next()) {
			"1" => "middle",
			"2" => "end",
			_ => "start",
		};
		const count = parseInt(this.next()) as int32;
		let text = `<text${this.transformAttr()} text-anchor="${anchor}">`;
		for (let i = 0; i < count; i += 1) {
			const hasX = this.next() === "1";
			const x = this.next();
			const hasY = this.next() === "1";
			const y = this.next();
			const dx = this.next();
			const dy = this.next();
			const size = this.next();
			const bold = this.next() === "1";
			const parts: string[] = this.color().split("\x1f");
			const content = escapeXml(unescapeText(this.next()));
			let span = "<tspan";
			if (hasX) { span += ` x="${x}"`; }
			if (hasY) { span += ` y="${y}"`; }
			if (dx !== "0") { span += ` dx="${dx}"`; }
			if (dy !== "0") { span += ` dy="${dy}"`; }
			span += ` font-size="${size}"${bold ? " font-weight=\"bold\"" : ""} fill="${parts[0]}" fill-opacity="${parts[1]}">`;
			text += span + content + "</tspan>";
		}
		this.body += text + "</text>";
	}

	run(): SvgMarkup {
		let viewBox = "";
		let aspect = "";
		while (this.at < this.tokens.length) {
			const op = this.next();
			const n = arity(op);
			if (n > 0 || op === "Z") {
				this.path += (this.path === "" ? "" : " ") + op;
				for (let i = 0; i < n; i += 1) { this.path += " " + this.next(); }
			} else if (op === "V") {
				viewBox = this.take(4);
				const align = alignName(this.next());
				const slice = this.next() === "1";
				aspect = align === "none" ? "none" : align + (slice ? " slice" : " meet");
			} else if (op === "X") {
				const m = this.take(6);
				this.matrix = m === "1 0 0 1 0 0" ? "" : m;
			} else if (op === "F") {
				this.fill = this.paint("fill");
			} else if (op === "S") {
				this.stroke = this.paint("stroke");
			} else if (op === "E") {
				this.rule = this.next();
			} else if (op === "W") {
				const width = this.next();
				const cap = match (this.next()) {
					"1" => "round",
					"2" => "square",
					_ => "butt",
				};
				const join = match (this.next()) {
					"1" => "round",
					"2" => "bevel",
					_ => "miter",
				};
				const miter = this.next();
				this.strokeAttrs = ` stroke-width="${width}" stroke-linecap="${cap}" stroke-linejoin="${join}" stroke-miterlimit="${miter}"`;
			} else if (op === "D") {
				const count = parseInt(this.next()) as int32;
				let dashes = "";
				for (let i = 0; i < count; i += 1) { dashes += (i === 0 ? "" : " ") + this.next(); }
				const offset = this.next();
				if (count > 0) { this.strokeAttrs += ` stroke-dasharray="${dashes}" stroke-dashoffset="${offset}"`; }
			} else if (op === "O") {
				const stroked = !this.stroke.startsWith("stroke=\"none\"");
				const rule = this.rule === "1" ? " fill-rule=\"evenodd\"" : "";
				this.body += this.defs + `<path d="${this.path}"${this.transformAttr()} ${this.fill}${rule} ${this.stroke}${stroked ? this.strokeAttrs : ""}/>`;
				this.defs = "";
				this.path = "";
				this.strokeAttrs = "";
			} else if (op === "K") {
				const id = this.nextId("c");
				const rule = this.rule === "1" ? " clip-rule=\"evenodd\"" : "";
				this.body += `<clipPath id="${id}"><path d="${this.path}"${this.transformAttr()}${rule}/></clipPath><g clip-path="url(#${id})">`;
				this.path = "";
			} else if (op === "k" || op === "g") {
				this.body += "</g>";
			} else if (op === "G") {
				const alpha = this.next();
				this.body += `<g opacity="${alpha}">`;
			} else if (op === "T") {
				this.textRuns();
			} else {
				throw new Error(`svg markup: unknown display-list op "${op}"`);
			}
		}
		return { viewBox, preserveAspectRatio: aspect, body: this.body };
	}
}

// `prefix` keeps gradient and clip ids unique in the document.
export function svgMarkup(list: string, prefix: string): SvgMarkup {
	return new MarkupWriter(list, prefix).run();
}
