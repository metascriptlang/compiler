// Trim and case conversion with the ECMAScript result, shared by the C and Raiser tiers (caseText.cms, caseText.rms):
// trim drops WhiteSpace and LineTerminator, case follows the default Unicode mapping with SpecialCasing and
// Final_Sigma. An ill-formed byte and an encoded surrogate map to themselves.

import { CaseRun, CaseFull, CaseSpan, casedSpans, caseIgnorableSpans } from "./caseTables";

const noCodePoint: uint32 = 0xFFFFFFFF;

struct CodePoint {
	cp: uint32;
	width: int64;
}

struct Mapped {
	one: uint32;
	full: int64;
}

export struct ByteRange {
	start: int64;
	end: int64;
}

@inline
function isContinuation(b: uint8): boolean {
	return (b & 0xC0) == 0x80;
}

@inline
function decodeAt(s: Readonly<Span<uint8>>, at: int64, end: int64): CodePoint {
	const b = s[at] as uint32;
	const n = end - at;
	if (b < 0x80) return { cp: b, width: 1 };
	if (b >= 0xC2 && b <= 0xDF && n >= 2 && isContinuation(s[at + 1])) {
		return { cp: ((b & 0x1F) << 6) | ((s[at + 1] as uint32) & 0x3F), width: 2 };
	}
	if (b >= 0xE0 && b <= 0xEF && n >= 3 && isContinuation(s[at + 1]) && isContinuation(s[at + 2])) {
		return { cp: ((b & 0x0F) << 12) | (((s[at + 1] as uint32) & 0x3F) << 6) | ((s[at + 2] as uint32) & 0x3F), width: 3 };
	}
	if (b >= 0xF0 && b <= 0xF4 && n >= 4 && isContinuation(s[at + 1]) && isContinuation(s[at + 2]) && isContinuation(s[at + 3])) {
		const cp = ((b & 0x07) << 18) | (((s[at + 1] as uint32) & 0x3F) << 12) | (((s[at + 2] as uint32) & 0x3F) << 6) | ((s[at + 3] as uint32) & 0x3F);
		return { cp: cp, width: 4 };
	}
	return { cp: noCodePoint, width: 1 };
}

function decodeBefore(s: Readonly<Span<uint8>>, end: int64): CodePoint {
	let k = end - 1;
	let steps = 0;
	while (k > 0 && steps < 3 && isContinuation(s[k])) {
		k = k - 1;
		steps = steps + 1;
	}
	const d = decodeAt(s, k, end);
	if (k + d.width != end) return { cp: noCodePoint, width: 1 };
	return d;
}

@inline
function cpWidth(cp: uint32): int64 {
	return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
}

@inline
function encodeAt(cp: uint32, out: Span<uint8>, at: int64): void {
	if (cp < 0x80) {
		out[at] = cp as uint8;
	} else if (cp < 0x800) {
		out[at] = (0xC0 | (cp >> 6)) as uint8;
		out[at + 1] = (0x80 | (cp & 0x3F)) as uint8;
	} else if (cp < 0x10000) {
		out[at] = (0xE0 | (cp >> 12)) as uint8;
		out[at + 1] = (0x80 | ((cp >> 6) & 0x3F)) as uint8;
		out[at + 2] = (0x80 | (cp & 0x3F)) as uint8;
	} else {
		out[at] = (0xF0 | (cp >> 18)) as uint8;
		out[at + 1] = (0x80 | ((cp >> 12) & 0x3F)) as uint8;
		out[at + 2] = (0x80 | ((cp >> 6) & 0x3F)) as uint8;
		out[at + 3] = (0x80 | (cp & 0x3F)) as uint8;
	}
}

function inSpans(t: Readonly<Span<CaseSpan>>, cp: uint32): boolean {
	let lo: int64 = 0;
	let hi = t.length as int64;
	while (lo < hi) {
		const mid = lo + ((hi - lo) >> 1);
		if (cp < t[mid].lo) hi = mid;
		else if (cp > t[mid].hi) lo = mid + 1;
		else return true;
	}
	return false;
}

@inline
function runTarget(t: Readonly<Span<CaseRun>>, cp: uint32): uint32 {
	let lo: int64 = 0;
	let hi = t.length as int64;
	while (lo < hi) {
		const mid = lo + ((hi - lo) >> 1);
		if (cp < t[mid].lo) hi = mid;
		else if (cp > t[mid].hi) lo = mid + 1;
		else if ((cp - t[mid].lo) % t[mid].stride != 0) return cp;
		else return ((cp as int64) + (t[mid].delta as int64)) as uint32;
	}
	return cp;
}

@inline
function fullIndex(t: Readonly<Span<CaseFull>>, cp: uint32): int64 {
	let lo: int64 = 0;
	let hi = t.length as int64;
	while (lo < hi) {
		const mid = lo + ((hi - lo) >> 1);
		if (cp < t[mid].cp) hi = mid;
		else if (cp > t[mid].cp) lo = mid + 1;
		else return mid;
	}
	return -1;
}

// A sigma at [at, after) is final when a cased letter precedes it and none follows, case-ignorable code points skipped.
function finalSigma(s: Readonly<Span<uint8>>, at: int64, after: int64): boolean {
	const n = s.length as int64;
	let j = at;
	let cp = noCodePoint;
	while (true) {
		if (j == 0) return false;
		const d = decodeBefore(s, j);
		j = j - d.width;
		cp = d.cp;
		if (!inSpans(caseIgnorableSpans, cp)) break;
	}
	if (!inSpans(casedSpans, cp)) return false;
	j = after;
	while (j < n) {
		const d = decodeAt(s, j, n);
		if (!inSpans(caseIgnorableSpans, d.cp)) return !inSpans(casedSpans, d.cp);
		j = j + d.width;
	}
	return true;
}

@inline
function mapAt(s: Readonly<Span<uint8>>, at: int64, d: CodePoint, runs: Readonly<Span<CaseRun>>, full: Readonly<Span<CaseFull>>, lower: boolean): Mapped {
	if (d.cp == noCodePoint) return { one: noCodePoint, full: -1 };
	if (lower && d.cp == 0x3A3) return { one: finalSigma(s, at, at + d.width) ? 0x3C2 : 0x3C3, full: -1 };
	const f = fullIndex(full, d.cp);
	if (f >= 0) return { one: d.cp, full: f };
	return { one: runTarget(runs, d.cp), full: -1 };
}

@inline
function flipAscii(b: uint8, from: uint8): uint8 {
	return ((b - from) as uint8) < 26 ? b ^ 0x20 : b;
}

@inline
export function asciiCaseInto(s: Readonly<Span<uint8>>, out: Span<uint8>, from: uint8): void {
	const n = s.length as int64;
	for (let i: int64 = 0; i < n; i++) out[i] = flipAscii(s[i], from);
}

/** The byte count `s` converts to with the case tables `runs` and `full`; `lower` applies Final_Sigma. */
@inline
export function caseLength(s: Readonly<Span<uint8>>, runs: Readonly<Span<CaseRun>>, full: Readonly<Span<CaseFull>>, lower: boolean): int64 {
	const n = s.length as int64;
	let i: int64 = 0;
	let o: int64 = 0;
	while (i < n) {
		if (s[i] < 0x80) {
			i = i + 1;
			o = o + 1;
			continue;
		}
		const d = decodeAt(s, i, n);
		const m = mapAt(s, i, d, runs, full, lower);
		if (m.full >= 0) {
			const f = full[m.full];
			for (let k = 0; k < 3 && f.out[k] != 0; k++) o = o + cpWidth(f.out[k]);
		} else if (m.one == d.cp) {
			o = o + d.width;
		} else {
			o = o + cpWidth(m.one);
		}
		i = i + d.width;
	}
	return o;
}

/** Writes the conversion `caseLength` measured into `out`. */
@inline
export function caseInto(s: Readonly<Span<uint8>>, out: Span<uint8>, runs: Readonly<Span<CaseRun>>, full: Readonly<Span<CaseFull>>, lower: boolean): void {
	const n = s.length as int64;
	const from: uint8 = lower ? 0x41 : 0x61;
	let i: int64 = 0;
	let o: int64 = 0;
	while (i < n) {
		const b = s[i];
		if (b < 0x80) {
			out[o] = flipAscii(b, from);
			i = i + 1;
			o = o + 1;
			continue;
		}
		const d = decodeAt(s, i, n);
		const m = mapAt(s, i, d, runs, full, lower);
		if (m.full >= 0) {
			const f = full[m.full];
			for (let k = 0; k < 3 && f.out[k] != 0; k++) {
				encodeAt(f.out[k], out, o);
				o = o + cpWidth(f.out[k]);
			}
		} else if (m.one == d.cp) {
			for (let k: int64 = 0; k < d.width; k++) out[o + k] = s[i + k];
			o = o + d.width;
		} else {
			encodeAt(m.one, out, o);
			o = o + cpWidth(m.one);
		}
		i = i + d.width;
	}
}

function isTrimmed(cp: uint32): boolean {
	return (cp >= 9 && cp <= 13) || cp == 0x20 || cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
		cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000 || cp == 0xFEFF;
}

/** The bytes of `s` left after trimming its start (`lead`) and its end (`trail`). */
export function trimmedRange(s: Readonly<Span<uint8>>, lead: boolean, trail: boolean): ByteRange {
	let a: int64 = 0;
	let b = s.length as int64;
	if (lead) {
		while (a < b) {
			const d = decodeAt(s, a, b);
			if (!isTrimmed(d.cp)) break;
			a = a + d.width;
		}
	}
	if (trail) {
		while (b > a) {
			const d = decodeBefore(s, b);
			if (b - d.width < a || !isTrimmed(d.cp)) break;
			b = b - d.width;
		}
	}
	return { start: a, end: b };
}
