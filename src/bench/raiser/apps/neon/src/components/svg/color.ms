// CSS colours as SVG paint takes them: #rgb, #rgba, #rrggbb, #rrggbbaa, rgb()/rgba()
// with numbers or percentages, hsl()/hsla(), the 148 CSS named colours and `transparent`.

export struct Rgba {
	r: int32;
	g: int32;
	b: int32;
	a: float64;
}

export enum ColorError {
	Unknown,
}

const NAMED_COLORS =
	"aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff " +
	"beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff " +
	"blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 " +
	"chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c " +
	"cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 " +
	"darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b " +
	"darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 " +
	"darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f " +
	"darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 " +
	"deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 " +
	"floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff " +
	"gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 " +
	"honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c " +
	"lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd " +
	"lightblue add8e6 lightcoral f08080 lightcyan e0ffff lightgoldenrodyellow fafad2 " +
	"lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a " +
	"lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 " +
	"lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 " +
	"magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd " +
	"mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee " +
	"mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 " +
	"midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 " +
	"navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 " +
	"orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 " +
	"paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 " +
	"peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 " +
	"rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 " +
	"salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d " +
	"silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 " +
	"snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 " +
	"tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff " +
	"whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32 ";

let namedTable: Map<string, string> | null = null;

function named(): Map<string, string> {
	if (namedTable !== null) { return namedTable as Map<string, string>; }
	const table = new Map<string, string>();
	const words: string[] = NAMED_COLORS.trim().split(" ");
	for (let i = 0; i + 1 < words.length; i += 2) { table.set(words[i], words[i + 1]); }
	namedTable = table;
	return table;
}

function hexDigit(code: int32): int32 {
	if (code >= 48 && code <= 57) { return code - 48; }
	if (code >= 97 && code <= 102) { return code - 87; }
	if (code >= 65 && code <= 70) { return code - 55; }
	return -1;
}

function parseHex(hex: string): Result<Rgba, ColorError> {
	const digits: int32[] = [];
	for (let i = 0; i < hex.length; i += 1) {
		const d = hexDigit(hex.charCodeAt(i));
		if (d < 0) { return Result.err(ColorError.Unknown); }
		digits.push(d);
	}
	if (digits.length === 3 || digits.length === 4) {
		const alpha = digits.length === 4 ? (digits[3] * 17) as float64 / 255 : 1.0;
		return Result.ok({ r: digits[0] * 17, g: digits[1] * 17, b: digits[2] * 17, a: alpha });
	}
	if (digits.length === 6 || digits.length === 8) {
		const alpha = digits.length === 8 ? (digits[6] * 16 + digits[7]) as float64 / 255 : 1.0;
		return Result.ok({ r: digits[0] * 16 + digits[1], g: digits[2] * 16 + digits[3], b: digits[4] * 16 + digits[5], a: alpha });
	}
	return Result.err(ColorError.Unknown);
}

function channel(text: string): int32 {
	const t = text.trim();
	if (t.endsWith("%")) {
		const p: float64 = parseFloat(t.substring(0, t.length - 1));
		return Math.round(Math.min(Math.max(p, 0), 100) * 2.55) as int32;
	}
	const v: float64 = parseFloat(t);
	return Math.round(Math.min(Math.max(v, 0), 255)) as int32;
}

function alphaOf(text: string): float64 {
	const t = text.trim();
	if (t.endsWith("%")) {
		const p: float64 = parseFloat(t.substring(0, t.length - 1));
		return Math.min(Math.max(p / 100, 0), 1);
	}
	const v: float64 = parseFloat(t);
	return Math.min(Math.max(v, 0), 1);
}

function percentOf(text: string): float64 {
	const t = text.trim();
	if (!t.endsWith("%")) { return NaN; }
	return Math.min(Math.max(parseFloat(t.substring(0, t.length - 1)), 0), 100) / 100;
}

function hueOf(text: string): float64 {
	const t = text.trim();
	const h: float64 = parseFloat(t.endsWith("deg") ? t.substring(0, t.length - 3) : t);
	return ((h % 360) + 360) % 360;
}

function hslChannel(n: int32, h: float64, s: float64, l: float64): int32 {
	const k = (n + h / 30) % 12;
	const a = s * Math.min(l, 1 - l);
	return Math.round((l - a * Math.max(-1, Math.min(Math.min(k - 3, 9 - k), 1))) * 255) as int32;
}

function parseHsl(body: string[]): Result<Rgba, ColorError> {
	const h = hueOf(body[0]);
	const s = percentOf(body[1]);
	const l = percentOf(body[2]);
	if (h !== h || s !== s || l !== l) { return Result.err(ColorError.Unknown); }
	return Result.ok({
		r: hslChannel(0, h, s, l),
		g: hslChannel(8, h, s, l),
		b: hslChannel(4, h, s, l),
		a: body.length === 4 ? alphaOf(body[3]) : 1.0,
	});
}

function parseFunction(text: string): Result<Rgba, ColorError> {
	const open = text.indexOf("(");
	const close = text.lastIndexOf(")");
	if (open < 0 || close < open) { return Result.err(ColorError.Unknown); }
	const name = text.substring(0, open).trim();
	const isRgb = name === "rgb" || name === "rgba";
	if (!isRgb && name !== "hsl" && name !== "hsla") { return Result.err(ColorError.Unknown); }
	const body = text.substring(open + 1, close).split("/").join(",").split(",");
	if (body.length !== 3 && body.length !== 4) { return Result.err(ColorError.Unknown); }
	if (!isRgb) { return parseHsl(body); }
	return Result.ok({
		r: channel(body[0]),
		g: channel(body[1]),
		b: channel(body[2]),
		a: body.length === 4 ? alphaOf(body[3]) : 1.0,
	});
}

export function parseColor(text: string): Result<Rgba, ColorError> {
	const t = text.trim();
	if (t.startsWith("#")) { return parseHex(t.substring(1, t.length)); }
	if (t.indexOf("(") >= 0) { return parseFunction(t); }
	const lower = t.toLowerCase();
	if (lower === "transparent") { return Result.ok({ r: 0, g: 0, b: 0, a: 0.0 }); }
	const table = named();
	if (table.has(lower)) { return parseHex(table.get(lower) as string); }
	return Result.err(ColorError.Unknown);
}
