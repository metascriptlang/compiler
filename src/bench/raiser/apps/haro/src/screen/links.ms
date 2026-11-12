export struct UrlRange {
	from: int32;
	to: int32;
}

const SCHEMES: Readonly<string[]> = [
	"https://", "http://", "mailto:", "ftp://", "file:", "ssh:", "git://", "tel:", "magnet:",
	"ipfs://", "ipns://", "gemini://", "gopher://", "news:",
];

const URL_PUNCTUATION = "-.~:/?#@!$&*+,;=%";
const NON_WORD_RANGES: Readonly<int32[]> = [0xA0, 0xA0, 0x2000, 0x206F, 0x3000, 0x303F];

function isWord(c: int32): boolean {
	if (c >= 0x80) {
		for (let i = 0; i < NON_WORD_RANGES.length; i += 2) {
			if (c >= NON_WORD_RANGES[i] && c <= NON_WORD_RANGES[i + 1]) { return false; }
		}
		return true;
	}
	return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
}

function isUrlChar(c: int32): boolean {
	return isWord(c) || (c < 0x80 && URL_PUNCTUATION.indexOf(String.fromCharCode(c)) >= 0);
}

function isHex(c: int32): boolean {
	return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
}

function unitAt(text: string, i: int32): int32 {
	return i < text.length ? text.charCodeAt(i) as int32 : -1;
}

function ipv6End(text: string, from: int32): int32 {
	if (unitAt(text, from) != 0x5B) { return -1; }
	let i = from + 1;
	while (isHex(unitAt(text, i)) || unitAt(text, i) == 0x3A) { i++; }
	if (i == from + 1 || unitAt(text, i) != 0x5D) { return -1; }
	i++;
	if (unitAt(text, i) != 0x3A) { return i; }
	let j = i + 1;
	while (unitAt(text, j) >= 0x30 && unitAt(text, j) <= 0x39) { j++; }
	return j > i + 1 ? j : i;
}

function charsEnd(text: string, from: int32): int32 {
	let i = from;
	while (isUrlChar(unitAt(text, i))) { i++; }
	return i;
}

function bracketedEnd(text: string, from: int32): int32 {
	const open = unitAt(text, from);
	if (open != 0x28 && open != 0x5B) { return from; }
	let i = from + 1;
	while (isWord(unitAt(text, i))) { i++; }
	const close = unitAt(text, i);
	return close == 0x29 || close == 0x5D ? i + 1 : from;
}

function schemeAt(text: string, i: int32): int32 {
	for (const scheme of SCHEMES) {
		if (text.charCodeAt(i) == scheme.charCodeAt(0) && text.slice(i, i + scheme.length) == scheme) {
			return scheme.length as int32;
		}
	}
	return 0;
}

function urlEnd(text: string, bodyFrom: int32): int32 {
	let end = bodyFrom;
	while (true) {
		const v6 = ipv6End(text, end);
		if (v6 >= 0) {
			end = v6;
			continue;
		}
		const run = charsEnd(text, end);
		if (run == end) { break; }
		end = bracketedEnd(text, run);
	}
	while (end > bodyFrom && (unitAt(text, end - 1) == 0x2C || unitAt(text, end - 1) == 0x2E)) { end--; }
	return end > bodyFrom ? end : -1;
}

export function urlSpans(text: string): Vec<UrlRange> {
	let spans: Vec<UrlRange> = [];
	let i = 0;
	while (i < text.length) {
		const scheme = schemeAt(text, i);
		const end = scheme > 0 ? urlEnd(text, i + scheme) : -1;
		if (end < 0) {
			i++;
			continue;
		}
		spans.push({ from: i, to: end });
		i = end;
	}
	return spans;
}

export function urlAt(text: string, at: int32): UrlRange | null {
	for (const span of urlSpans(text)) {
		if (at >= span.from && at < span.to) { return span; }
	}
	return null;
}
