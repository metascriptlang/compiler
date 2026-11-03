export function quoted(s: string): string {
	return "\"" + s.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"") + "\"";
}

const GLUE = [
	"const __msbTe = new TextEncoder();",
	"const __msbTd = new TextDecoder('utf-8', { ignoreBOM: true });",
	"function __msbHeapAlloc(n) {",
	"\tconst p = n > 4294967295 ? 0 : __msbMod._malloc(n);",
	"\tif (p === 0) throw new RangeError(\"wasm heap exhausted: cannot copy \" "
		+ "+ n + \" bytes into wasm memory\");",
	"\treturn p;",
	"}",
	"function __msbAlloc(n) {",
	"\tconst room = __msbEnd - __msbTop;",
	"\tif (n <= room) {",
	"\t\tconst a = n + 15 & -16;",
	"\t\tif (a <= room) {",
	"\t\t\tconst q = __msbTop;",
	"\t\t\t__msbTop = q + a;",
	"\t\t\treturn q;",
	"\t\t}",
	"\t}",
	"\treturn __msbHeapAlloc(n);",
	"}",
	"function __msbFree(p) {",
	"\tif (p < __msbBase || p >= __msbEnd) __msbMod._free(p);",
	"}",
	"function __msbInRange(a, off, n) {",
	"\tif (!(off >= 0 && (n === 0 || n >= 0 && off + n <= a.length))) throw new "
		+ "RangeError(\"Span out of range of its array: offset \" + off + \", "
		+ "length \" + n + \", array length \" + a.length + \" (was the array "
		+ "resized while lent?)\");",
	"}",
	"function __msbCopyIn(a, off, n, T) {",
	"\t__msbInRange(a, off, n);",
	"\tconst p = __msbAlloc(n * T.BYTES_PER_ELEMENT || 1);",
	"\t__msbCopyTo(p, a, off, n, T);",
	"\treturn [p, n];",
	"}",
	"function __msbCopyTo(p, a, off, n, T) {",
	"\t__msbInRange(a, off, n);",
	"\tconst v = new T(__msbMod.HEAPU8.buffer, p, n);",
	"\tif (ArrayBuffer.isView(a)) v.set(a.subarray(off, off + n));",
	"\telse for (let i = 0; i < n; i++) v[i] = a[off + i];",
	"}",
	"function __msbCopyBack(p, a, off, n, T, bool) {",
	"\t__msbInRange(a, off, n);",
	"\tconst v = new T(__msbMod.HEAPU8.buffer, p, n);",
	"\tif (!bool && n !== 0 && ArrayBuffer.isView(a)) a.set(v, off);",
	"\telse for (let i = 0; i < n; i++) a[off + i] = bool ? v[i] !== 0 : v[i];",
	"}",
	"function __msbVecOut(p, n, T, bool) {",
	"\tconst v = new T(__msbMod.HEAPU8.buffer, p, n);",
	"\tconst r = new Array(n);",
	"\tfor (let i = 0; i < n; i++) r[i] = bool ? v[i] !== 0 : v[i];",
	"\treturn r;",
	"}",
	"function __msbSeal(h, p, n) {",
	"\th[p] = n; h[p + 1] = n >>> 8; h[p + 2] = n >>> 16; h[p + 3] = n >>> 24;",
	"\th[p + 4] = 0; h[p + 5] = 0; h[p + 6] = 0; h[p + 7] = 0;",
	"\th[p + 8 + n] = 0;",
	"\treturn [p, n];",
	"}",
	"function __msbEncAt(s, own) {",
	"\tconst n = s.length;",
	"\tif (own && n === 0) return [0, 0];",
	"\tconst hd = own ? 8 : 0;",
	"\tlet i = 0;",
	"\twhile (i < n && s.charCodeAt(i) < 128) i++;",
	"\tif (i === n) {",
	"\t\tconst p = __msbHeapAlloc(own ? n + 9 : n || 1);",
	"\t\tconst h = __msbMod.HEAPU8;",
	"\t\t__msbTe.encodeInto(s, h.subarray(p + hd, p + hd + n));",
	"\t\treturn own ? __msbSeal(h, p, n) : [p, n];",
	"\t}",
	"\tlet cap = n * 3;",
	"\tif (n > 4096) {",
	"\t\tcap = i;",
	"\t\tfor (let j = i; j < n; j++) {",
	"\t\t\tconst c = s.charCodeAt(j);",
	"\t\t\tif (c < 128) cap++;",
	"\t\t\telse if (c < 2048) cap += 2;",
	"\t\t\telse if (c >= 0xd800 && c < 0xdc00 && j + 1 < n && (s.charCodeAt(j + "
		+ "1) & 0xfc00) === 0xdc00) { cap += 4; j++; }",
	"\t\t\telse cap += 3;",
	"\t\t}",
	"\t}",
	"\tconst p = __msbHeapAlloc(own ? cap + 9 : cap);",
	"\tconst h = __msbMod.HEAPU8;",
	"\tlet o = p + hd;",
	"\tfor (i = 0; i < n; i++) {",
	"\t\tlet c = s.charCodeAt(i);",
	"\t\tif (c < 128) h[o++] = c;",
	"\t\telse if (c < 2048) { h[o++] = 192 | c >> 6; h[o++] = 128 | c & 63; }",
	"\t\telse if (c >= 0xd800 && c < 0xdc00 && i + 1 < n && (s.charCodeAt(i + "
		+ "1) & 0xfc00) === 0xdc00) {",
	"\t\t\tc = 0x10000 + ((c & 1023) << 10 | s.charCodeAt(++i) & 1023);",
	"\t\t\th[o++] = 240 | c >> 18; h[o++] = 128 | c >> 12 & 63; h[o++] = 128 | "
		+ "c >> 6 & 63; h[o++] = 128 | c & 63;",
	"\t\t} else { h[o++] = 224 | c >> 12; h[o++] = 128 | c >> 6 & 63; h[o++] = "
		+ "128 | c & 63; }",
	"\t}",
	"\tif (o - p - hd > cap) throw new Error(\"internal: string encoder wrote "
		+ "\" + (o - p - hd) + \" bytes into a block of \" + cap);",
	"\treturn own ? __msbSeal(h, p, o - p - hd) : [p, o - p];",
	"}",
	"function __msbEnc(s) {",
	"\treturn __msbEncAt(s, false);",
	"}",
	"function __msbEncOwned(s) {",
	"\treturn __msbEncAt(s, true);",
	"}",
	"function __msbDecLoop(h, p, end) {",
	"\tlet r = \"\";",
	"\twhile (p < end) {",
	"\t\tconst x = h[p];",
	"\t\tif (x < 128) { r += String.fromCharCode(x); p++; }",
	"\t\telse if (x < 224) { r += String.fromCharCode((x & 31) << 6 | h[p + 1] "
		+ "& 63); p += 2; }",
	"\t\telse if (x < 240) { r += String.fromCharCode((x & 15) << 12 | (h[p + "
		+ "1] & 63) << 6 | h[p + 2] & 63); p += 3; }",
	"\t\telse {",
	"\t\t\tconst c = ((x & 7) << 18 | (h[p + 1] & 63) << 12 | (h[p + 2] & 63) "
		+ "<< 6 | h[p + 3] & 63) - 65536;",
	"\t\t\tr += String.fromCharCode(55296 + (c >> 10), 56320 + (c & 1023)); p "
		+ "+= 4;",
	"\t\t}",
	"\t}",
	"\treturn r;",
	"}",
	"function __msbDec(p, len) {",
	"\tconst h = __msbMod.HEAPU8;",
	"\tif (len <= 16) return __msbDecLoop(h, p, p + len);",
	"\tconst e = p + len;",
	"\tconst s = __msbTd.decode(h.subarray(p, e));",
	"\tif (s.indexOf(\"\\uFFFD\") < 0) return s;",
	"\tfor (let i = p; i + 1 < e; i++) {",
	"\t\tif (h[i] === 0xed && h[i + 1] >= 0xa0) return __msbDecLoop(h, p, e);",
	"\t}",
	"\treturn s;",
	"}",
];

const VIEW_GROUPS = [
	"function __msbGroups(vs) {",
	"\tconst g = vs.map((v, i) => i);",
	"\tfor (let i = 1; i < vs.length; i++) {",
	"\t\tfor (let j = 0; j < i; j++) {",
	"\t\t\tconst a = vs[i], b = vs[j];",
	"\t\t\tif (a !== null && b !== null && a[2] > 0 && b[2] > 0 && a[0] === "
		+ "b[0] && a[1] < b[1] + b[2] && b[1] < a[1] + a[2] && g[i] !== g[j]) {",
	"\t\t\t\tconst from = g[i];",
	"\t\t\t\tfor (let k = 0; k < g.length; k++) if (g[k] === from) g[k] = g[j];",
	"\t\t\t}",
	"\t\t}",
	"\t}",
	"\tconst groups = [];",
	"\tfor (let c = 0; c < vs.length; c++) {",
	"\t\tconst m = [];",
	"\t\tfor (let k = 0; k < vs.length; k++) if (g[k] === c) m.push(k);",
	"\t\tif (m.length > 0) groups.push(m);",
	"\t}",
	"\treturn groups;",
	"}",
];

const VIEWS_IN = [
	"function __msbCopyInViews(vs, blocks, f) {",
	"\tfor (const v of vs) if (v !== null) __msbInRange(v[0], v[1], v[2]);",
	"\tfor (const a of vs) for (const b of vs) {",
	"\t\tif (a !== null && b !== null && a[4] === \"copy\" && b[4] === "
		+ "\"write\" && a[0] === b[0] && a[2] > 0 && b[2] > 0 && a[1] < b[1] + "
		+ "b[2] && b[1] < a[1] + a[2]) {",
	"\t\t\tthrow new Error(f + \": \" + a[5] + \" is a Vec copied when the call "
		+ "starts and \" + b[5] + \" writes elements it holds, so the copy would "
		+ "miss the write: declare \" + a[5] + \" as a Readonly<Span>, which sees "
		+ "it\");",
	"\t\t}",
	"\t}",
	"\tconst r = new Array(vs.length).fill(null);",
	"\tfor (const m of __msbGroups(vs)) {",
	"\t\tif (vs[m[0]] === null) continue;",
	"\t\tconst T = vs[m[0]][3];",
	"\t\tfor (const k of m) if (vs[k][3] !== T) throw new Error(\"internal: "
		+ "views of one array differ in element type\");",
	"\t\tconst lo = Math.min(...m.map((k) => vs[k][1]));",
	"\t\tconst hi = Math.max(...m.map((k) => vs[k][1] + vs[k][2]));",
	"\t\tconst p = __msbAlloc((hi - lo) * T.BYTES_PER_ELEMENT || 1);",
	"\t\tblocks.push(p);",
	"\t\t__msbCopyTo(p, vs[m[0]][0], lo, hi - lo, T);",
	"\t\tfor (const k of m) r[k] = [p + (vs[k][1] - lo) * T.BYTES_PER_ELEMENT, "
		+ "vs[k][2]];",
	"\t}",
	"\treturn r;",
	"}",
];

const VIEWS_OUT = [
	"function __msbVecViews(rs) {",
	"\tconst out = new Array(rs.length);",
	"\tfor (const m of __msbGroups(rs.map((r) => [0, r[0], r[1] * "
		+ "r[2].BYTES_PER_ELEMENT]))) {",
	"\t\tconst T = rs[m[0]][2];",
	"\t\tfor (const k of m) if (rs[k][2] !== T) throw new Error(\"internal: "
		+ "views of one memory range differ in element type\");",
	"\t\tconst B = T.BYTES_PER_ELEMENT;",
	"\t\tconst lo = Math.min(...m.map((k) => rs[k][0]));",
	"\t\tconst hi = Math.max(...m.map((k) => rs[k][0] + rs[k][1] * B));",
	"\t\tconst base = __msbVecOut(lo, (hi - lo) / B, T, rs[m[0]][3]);",
	"\t\tfor (const k of m) out[k] = { base, off: (rs[k][0] - lo) / B, len: "
		+ "rs[k][1] };",
	"\t}",
	"\treturn out;",
	"}",
];

const CHECK_GLUE = [
	"function __msbBad(f, p, t, v) {",
	"\treturn new TypeError(f + \": \" + p + \" expected \" + t + \", found \" "
		+ "+ (v === null ? \"null\" : Array.isArray(v) ? \"array\" : typeof v));",
	"}",
	"function __msbType(v, k, t, f, p) {",
	"\tif (typeof v !== k || v === null) throw __msbBad(f, p, t, v);",
	"\treturn v;",
	"}",
	"function __msbInt(v, k, lo, hi, t, f, p) {",
	"\tif (typeof v !== k) throw __msbBad(f, p, t, v);",
	"\tif (v < lo || v > hi || (k === \"number\" && !Number.isInteger(v))) "
		+ "throw new RangeError(f + \": \" + p + \" expected \" + t + \", got \" "
		+ "+ v);",
	"\treturn v;",
	"}",
	"function __msbWide(v, s, t, f, p) {",
	"\tif (typeof v !== \"bigint\") throw __msbBad(f, p, t, v);",
	"\tif ((s ? BigInt.asIntN(64, v) : BigInt.asUintN(64, v)) !== v) throw new "
		+ "RangeError(f + \": \" + p + \" expected \" + t + \", got \" + v);",
	"\treturn v;",
	"}",
	"function __msbList(v, t, f, p) {",
	"\tif (typeof v !== \"object\" || v === null || !Number.isInteger(v.length) "
		+ "|| v.length < 0) throw __msbBad(f, p, t, v);",
	"\treturn v;",
	"}",
	"function __msbSpan(v, t, f, p) {",
	"\t__msbType(v, \"object\", t, f, p);",
	"\t__msbList(v.base, \"array\", f, p + \" base\");",
	"\tif (!Number.isInteger(v.off) || !Number.isInteger(v.len)) throw new "
		+ "TypeError(f + \": \" + p + \" expected \" + t + \" with integer off "
		+ "and len, got off \" + v.off + \" len \" + v.len);",
	"\treturn v;",
	"}",
	"function __msbElems(v, off, n, k, lo, hi, t, f, p) {",
	"\tif (k === \"boolean\" && ArrayBuffer.isView(v)) return v;",
	"\tif (k === \"number\" && lo === null && (v instanceof Float32Array "
		+ "|| v instanceof Float64Array)) return v;",
	"\tconst end = Math.min(off + n, v.length);",
	"\tfor (let i = Math.max(off, 0); i < end; i++) {",
	"\t\tconst x = v[i];",
	"\t\tif (typeof x === k && (lo === null || (x >= lo && x <= hi && (k !== "
		+ "\"number\" || Number.isInteger(x))))) continue;",
	"\t\tif (lo === null) __msbType(x, k, t, f, p + \" element \" + (i - off));",
	"\t\t__msbInt(x, k, lo, hi, t, f, p + \" element \" + (i - off));",
	"\t}",
	"\treturn v;",
	"}",
];

const SLOT_LIMIT = 0x1000000;

const HANDLE_STATE = [
	"\tconst hk = [];",
	"\tconst hv = [];",
	"\tconst hl = [];",
	"\tconst hr = [];",
	"\tconst hu = [];",
	"\tconst hf = [];",
	"\tlet hUid = 1;",
	"\tconst hLive = (r) => r.i < hk.length && hu[r.i] === r.u && hk[r.i] === 2;",
	"\tconst hFinish = (i) => {",
	"\t\tconst p = hv[i];",
	"\t\thk[i] = 0;",
	"\t\thv[i] = undefined;",
	"\t\thf.push(i);",
	"\t\tif (!dead) __msbMod._msb_release(p);",
	"\t};",
];

const HANDLE_METHODS = [
	"\t\town(p, type, label) {",
	"\t\t\tlet i = hf.pop();",
	"\t\t\tif (i === undefined) {",
	`\t\t\t\tif (hk.length >= ${SLOT_LIMIT}) throw new RangeError("boundary slot table full");`,
	"\t\t\t\ti = hk.length;",
	"\t\t\t\thk.push(0); hv.push(0); hl.push(0); hr.push(0); hu.push(0);",
	"\t\t\t}",
	"\t\t\thk[i] = 2; hv[i] = p; hl[i] = 0; hr[i] = 1; hu[i] = hUid++;",
	"\t\t\treturn new __msbRef(i, hu[i], label || type);",
	"\t\t},",
	"\t\tlive(r) { return hLive(r); },",
	"\t\tlend(r) {",
	"\t\t\tif (!(r instanceof __msbRef)) throw new TypeError(\"expected a Handle "
		+ "returned by a @wasm function\");",
	"\t\t\tif (!hLive(r)) throw new Error(\"use of \" + r.name + \" after "
		+ "release\");",
	"\t\t\thl[r.i]++;",
	"\t\t\treturn hv[r.i];",
	"\t\t},",
	"\t\tunlend(r) { if (--hl[r.i] === 0 && hk[r.i] === 3) hFinish(r.i); },",
	"\t\tretain(r) {",
	"\t\t\tif (!hLive(r)) throw new Error(\"use of \" + r.name + \" after "
		+ "release\");",
	"\t\t\thr[r.i]++;",
	"\t\t},",
	"\t\trelease(r) {",
	"\t\t\tif (!hLive(r)) throw new Error(\"release of \" + r.name + \": "
		+ "already released\");",
	"\t\t\tif (--hr[r.i] !== 0) return;",
	"\t\t\tif (hl[r.i] > 0) hk[r.i] = 3;",
	"\t\t\telse hFinish(r.i);",
	"\t\t},",
];

const HANDLE_GLUE = [
	"class __msbRef {",
	"\tconstructor(i, u, name) { this.i = i; this.u = u; this.name = name; }",
	"\trelease() { __msb.release(this); }",
	"\tretain() { __msb.retain(this); return this; }",
	"\tget released() { return !__msb.live(this); }",
	"}",
	"__msbRef.prototype[Symbol.for(\"msb.ref\")] = true;",
	"if (Symbol.dispose) __msbRef.prototype[Symbol.dispose] = "
		+ "__msbRef.prototype.release;",
];

const SCRATCH_BYTES = 16384;

function scratchLines(used: boolean): string[] {
	if (!used) {
		return ["const __msbBase = 0;", "const __msbEnd = 0;", "let __msbTop = 0;"];
	}
	return [
		`const __msbBase = __msbMod._malloc(${SCRATCH_BYTES});`,
		`const __msbEnd = __msbBase === 0 ? 0 : __msbBase + ${SCRATCH_BYTES};`,
		"let __msbTop = __msbBase;",
	];
}

const SLOT_BITS: int32 = 16;
const SLOT_CAP: int32 = 1 << SLOT_BITS;
const SLOT_MASK: int32 = SLOT_CAP - 1;
const GEN_MASK: int32 = (1 << (31 - SLOT_BITS)) - 1;

export function preludeFor(
	wasmModuleUrl: string,
	checked: boolean,
	scratch: boolean,
	views: string[],
	handles: boolean,
): string {
	const tableFull = `boundary table full: ${SLOT_CAP} live entries`;
	const staleSlot = `vals[s] === undefined || gens[s] !== id >>> ${SLOT_BITS}`;
	const rejectStale = (message: string): string => {
		return `\t\t\tif (${staleSlot}) throw new Error("${message}");`;
	};
	const rejectFull = `throw new RangeError("${tableFull}")`;
	const deadGlue = "the wasm half cannot run again: a trap or a host error "
		+ "left its frames unfinished";
	const lentGlue = "a wasm function was called while a Span was lent to a JS "
		+ "callback: the callback's copy and the wasm side's would diverge, so "
		+ "call it after the callback returns";
	const base = checked
		? GLUE.concat(views).concat(CHECK_GLUE)
		: GLUE.concat(views);
	const glue = handles ? base.concat(HANDLE_GLUE) : base;
	const factory = `(await import(${quoted(wasmModuleUrl)})).default`;
	return [
		"const __msb = (() => {",
		"\tconst vals = [];",
		"\tconst gens = [];",
		"\tconst free = [];",
		"\tlet dead = false;",
		"\tlet cause;",
		"\tlet pending = null;",
		"\tlet escaped = null;",
		...(handles ? HANDLE_STATE : []),
		"\treturn {",
		...(handles ? HANDLE_METHODS : []),
		"\t\tpush(f) {",
		"\t\t\tlet s = free.pop();",
		"\t\t\tif (s === undefined) {",
		`\t\t\t\tif (vals.length >= ${SLOT_CAP}) ${rejectFull};`,
		"\t\t\t\ts = vals.length;",
		"\t\t\t\tvals.push(undefined);",
		"\t\t\t\tgens.push(0);",
		"\t\t\t}",
		"\t\t\tvals[s] = f;",
		`\t\t\treturn (gens[s] << ${SLOT_BITS}) | s;`,
		"\t\t},",
		"\t\tpop(id) {",
		`\t\t\tconst s = id & ${SLOT_MASK};`,
		rejectStale("boundary entry released twice"),
		"\t\t\tvals[s] = undefined;",
		`\t\t\tgens[s] = (gens[s] + 1) & ${GEN_MASK};`,
		"\t\t\tfree.push(s);",
		"\t\t},",
		"\t\ttakes: [],",
		"\t\tdirty: false,",
		"\t\tlent: 0,",
		"\t\tcb(id) {",
		`\t\t\tconst s = id & ${SLOT_MASK};`,
		rejectStale("callback used after its call returned"),
		"\t\t\treturn vals[s];",
		"\t\t},",
		`\t\tenter() {`,
		`\t\t\tif (dead) throw new Error("${deadGlue}", { cause });`,
		`\t\t\tif (this.lent !== 0) throw new Error("${lentGlue}");`,
		"\t\t},",
		"\t\tdie(e) { if (!dead) { dead = true; cause = e; } return e; },",
		"\t\tfail(e, z) {",
		"\t\t\tif (dead) throw e;",
		"\t\t\tconst m = String(e?.message ?? e);",
		"\t\t\tpending = [e, m];",
		"\t\t\tthis.dirty = true;",
		"\t\t\tconst b = __msbEncOwned(m);",
		"\t\t\t__msbMod._msb_fail(b[0], b[1]);",
		"\t\t\treturn z;",
		"\t\t},",
		"\t\tescape(p, n) { escaped = __msbDec(p >>> 0, n); this.dirty = true; },",
		"\t\tleave() {",
		"\t\t\tthis.dirty = false;",
		"\t\t\tconst p = pending;",
		"\t\t\tpending = null;",
		"\t\t\tif (escaped === null) return;",
		"\t\t\tconst m = escaped;",
		"\t\t\tescaped = null;",
		"\t\t\tthrow p !== null && p[1] === m ? p[0] : new Error(m);",
		"\t\t},",
		"\t};",
		"})();",
		glue.join("\n"),
		`const __msbMod = await ${factory}({ msb: __msb });`,
		"__msbMod._MsMain();",
		...scratchLines(scratch),
		"",
	].join("\n");
}

export function viewHelpers(viewsIn: boolean, viewsOut: boolean): string[] {
	const views: string[] = [];
	if (viewsIn || viewsOut) {
		for (const l of VIEW_GROUPS) views.push(l);
	}
	if (viewsIn) for (const l of VIEWS_IN) views.push(l);
	if (viewsOut) for (const l of VIEWS_OUT) views.push(l);
	return views;
}
