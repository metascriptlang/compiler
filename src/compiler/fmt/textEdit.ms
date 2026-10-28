// Minimal edits between two texts. Both are cut into word, blank, line-break and punctuation
// tokens, the token sequences are diffed (Myers, linear space), and each changed run becomes one
// edit in byte offsets of the old text. Non-ASCII bytes count as word bytes, so an edit never
// splits a character.

export interface ByteEdit {
	start: int32;
	end: int32;
	newText: string;
}

enum TokenKind {
	Word,
	Blank,
	Single,
}

function kindOf(byte: int32): TokenKind {
	const letter = (byte >= "a".code && byte <= "z".code) || (byte >= "A".code && byte <= "Z".code);
	const digit = byte >= "0".code && byte <= "9".code;
	if (letter || digit || byte == "_".code || byte >= 0x80) return TokenKind.Word;
	if (byte == " ".code || byte == "\t".code || byte == "\r".code) return TokenKind.Blank;
	return TokenKind.Single;
}

function atCrLf(text: string, at: int32): boolean {
	return text.byteAt(at) == "\r".code && at + 1 < text.byteLength && text.byteAt(at + 1) == "\n".code;
}

function tokenEnds(text: string): int32[] {
	const ends: int32[] = [];
	let at: int32 = 0;
	while (at < text.byteLength) {
		if (atCrLf(text, at)) {
			at += 2;
		} else {
			const kind = kindOf(text.byteAt(at));
			at += 1;
			if (kind != TokenKind.Single) {
				while (at < text.byteLength && kindOf(text.byteAt(at)) == kind && !atCrLf(text, at)) at += 1;
			}
		}
		ends.push(at);
	}
	return ends;
}

function tokenStart(ends: int32[], index: int32): int32 {
	return index == 0 ? 0 : ends[index - 1];
}

function tokenIds(text: string, ends: int32[], ids: Map<string, int32>): int32[] {
	const result: int32[] = [];
	for (let i: int32 = 0; i < ends.length; i += 1) {
		const token = text.byteSlice(tokenStart(ends, i), ends[i]);
		const known = ids.get(token);
		if (known !== null) {
			result.push(known);
		} else {
			const id = ids.size as int32;
			ids.set(token, id);
			result.push(id);
		}
	}
	return result;
}

interface TokenDiff {
	a: int32[];
	b: int32[];
	removed: boolean[];
	added: boolean[];
	forward: int32[];
	backward: int32[];
}

function markRemoved(this d: TokenDiff, from: int32, to: int32): void {
	for (let i = from; i < to; i += 1) d.removed[i] = true;
}

function markAdded(this d: TokenDiff, from: int32, to: int32): void {
	for (let i = from; i < to; i += 1) d.added[i] = true;
}

// Where the forward and backward searches over a[aLo, aHi) and b[bLo, bHi) meet, as offsets from
// aLo and bLo; null when the two ranges share no token.
function middleSnake(this d: TokenDiff, aLo: int32, aHi: int32, bLo: int32, bHi: int32): [int32, int32] | null {
	const n = aHi - aLo;
	const m = bHi - bLo;
	const maxD = (n + m + 1) >> 1;
	const width = 2 * maxD + 2;
	for (let i: int32 = 0; i < width; i += 1) {
		d.forward[i] = -1;
		d.backward[i] = -1;
	}
	d.forward[maxD + 1] = 0;
	d.backward[maxD + 1] = 0;
	const delta = n - m;
	const front = delta % 2 != 0;
	let k1Start: int32 = 0;
	let k1End: int32 = 0;
	let k2Start: int32 = 0;
	let k2End: int32 = 0;
	for (let step: int32 = 0; step < maxD; step += 1) {
		for (let k1 = -step + k1Start; k1 <= step - k1End; k1 += 2) {
			const at = maxD + k1;
			let x1: int32 = 0;
			if (k1 == -step || (k1 != step && d.forward[at - 1] < d.forward[at + 1])) x1 = d.forward[at + 1];
			else x1 = d.forward[at - 1] + 1;
			let y1 = x1 - k1;
			while (x1 < n && y1 < m && d.a[aLo + x1] == d.b[bLo + y1]) {
				x1 += 1;
				y1 += 1;
			}
			d.forward[at] = x1;
			if (x1 > n) {
				k1End += 2;
			} else if (y1 > m) {
				k1Start += 2;
			} else if (front) {
				const mirror = maxD + delta - k1;
				if (mirror >= 0 && mirror < width && d.backward[mirror] != -1 && x1 >= n - d.backward[mirror]) return [x1, y1];
			}
		}
		for (let k2 = -step + k2Start; k2 <= step - k2End; k2 += 2) {
			const at = maxD + k2;
			let x2: int32 = 0;
			if (k2 == -step || (k2 != step && d.backward[at - 1] < d.backward[at + 1])) x2 = d.backward[at + 1];
			else x2 = d.backward[at - 1] + 1;
			let y2 = x2 - k2;
			while (x2 < n && y2 < m && d.a[aHi - x2 - 1] == d.b[bHi - y2 - 1]) {
				x2 += 1;
				y2 += 1;
			}
			d.backward[at] = x2;
			if (x2 > n) {
				k2End += 2;
			} else if (y2 > m) {
				k2Start += 2;
			} else if (!front) {
				const mirror = maxD + delta - k2;
				if (mirror >= 0 && mirror < width && d.forward[mirror] != -1) {
					const x1 = d.forward[mirror];
					if (x1 >= n - x2) return [x1, x1 - (mirror - maxD)];
				}
			}
		}
	}
	return null;
}

function conquer(this d: TokenDiff, lo1: int32, hi1: int32, lo2: int32, hi2: int32): void {
	let aLo = lo1;
	let aHi = hi1;
	let bLo = lo2;
	let bHi = hi2;
	while (aLo < aHi && bLo < bHi && d.a[aLo] == d.b[bLo]) {
		aLo += 1;
		bLo += 1;
	}
	while (aLo < aHi && bLo < bHi && d.a[aHi - 1] == d.b[bHi - 1]) {
		aHi -= 1;
		bHi -= 1;
	}
	if (aLo == aHi) {
		d.markAdded(bLo, bHi);
		return;
	}
	if (bLo == bHi) {
		d.markRemoved(aLo, aHi);
		return;
	}
	const snake = d.middleSnake(aLo, aHi, bLo, bHi);
	if (snake === null || (snake[0] == 0 && snake[1] == 0) || (snake[0] == aHi - aLo && snake[1] == bHi - bLo)) {
		d.markRemoved(aLo, aHi);
		d.markAdded(bLo, bHi);
		return;
	}
	d.conquer(aLo, aLo + snake[0], bLo, bLo + snake[1]);
	d.conquer(aLo + snake[0], aHi, bLo + snake[1], bHi);
}

// Edits in ascending order over byte offsets of `old`; applying them last to first yields `updated`.
// A removed run directly followed by an inserted one is one replacing edit.
export function diffTextEdits(old: string, updated: string): ByteEdit[] {
	const edits: ByteEdit[] = [];
	if (old == updated) return edits;
	const oldEnds = tokenEnds(old);
	const newEnds = tokenEnds(updated);
	const ids = new Map<string, int32>();
	const a = tokenIds(old, oldEnds, ids);
	const b = tokenIds(updated, newEnds, ids);
	const d: TokenDiff = { a, b, removed: [], added: [], forward: [], backward: [] };
	for (let i: int32 = 0; i < a.length; i += 1) d.removed.push(false);
	for (let j: int32 = 0; j < b.length; j += 1) d.added.push(false);
	const scratch = a.length + b.length + 3;
	for (let i: int32 = 0; i < scratch; i += 1) {
		d.forward.push(-1);
		d.backward.push(-1);
	}
	d.conquer(0, a.length, 0, b.length);

	let i: int32 = 0;
	let j: int32 = 0;
	while (i < a.length || j < b.length) {
		if (i < a.length && j < b.length && !d.removed[i] && !d.added[j]) {
			i += 1;
			j += 1;
		} else {
			const fromOld = i;
			const fromNew = j;
			while ((i < a.length && d.removed[i]) || (j < b.length && d.added[j])) {
				if (i < a.length && d.removed[i]) i += 1;
				if (j < b.length && d.added[j]) j += 1;
			}
			if (i == fromOld && j == fromNew) throw new Error("token diff lost alignment");
			edits.push({
				start: tokenStart(oldEnds, fromOld),
				end: tokenStart(oldEnds, i),
				newText: updated.byteSlice(tokenStart(newEnds, fromNew), tokenStart(newEnds, j)),
			});
		}
	}
	return edits;
}

function applied(old: string, edits: ByteEdit[]): string {
	let result = old;
	for (let i = edits.length - 1; i >= 0; i -= 1) {
		result = result.byteSlice(0, edits[i].start) + edits[i].newText + result.byteSlice(edits[i].end, result.byteLength);
	}
	return result;
}

function assertDiff(old: string, updated: string): ByteEdit[] {
	const edits = diffTextEdits(old, updated);
	if (applied(old, edits) != updated) throw new Error("edits do not reproduce the target: " + old);
	return edits;
}

test "empty and identical texts produce no edit" {
	assert diffTextEdits("", "").length == 0;
	assert diffTextEdits("a b\n", "a b\n").length == 0;
}

test "an insertion into empty text and a deletion to empty text are one edit each" {
	const inserted = assertDiff("", "abc");
	assert inserted.length == 1 && inserted[0].start == 0 && inserted[0].end == 0;
	const deleted = assertDiff("abc", "");
	assert deleted.length == 1 && deleted[0].start == 0 && deleted[0].end == 3;
}

test "an insertion changes nothing but the inserted bytes" {
	const edits = assertDiff("a=1;", "a = 1;");
	assert edits.length == 2;
	assert edits[0].start == 1 && edits[0].end == 1 && edits[0].newText == " ";
	assert edits[1].start == 2 && edits[1].end == 2 && edits[1].newText == " ";
}

test "a deletion changes nothing but the deleted bytes" {
	const edits = assertDiff("a   =  1;", "a = 1;");
	assert edits.length == 2;
	assert edits[0].start == 1 && edits[0].end == 4 && edits[0].newText == " ";
	assert edits[1].start == 5 && edits[1].end == 7 && edits[1].newText == " ";
}

test "a replaced word is one edit holding the new word" {
	const edits = assertDiff("let value = 1;", "let total = 1;");
	assert edits.length == 1;
	assert edits[0].start == 4 && edits[0].end == 9 && edits[0].newText == "total";
}

test "a change on one line leaves the lines around it alone" {
	const edits = assertDiff("a;\nb  =1;\nc;\n", "a;\nb = 1;\nc;\n");
	assert edits.length == 2;
	assert edits[0].start >= 3 && edits[1].end <= 9;
}

test "non-ASCII bytes stay whole before and inside a change" {
	const before = assertDiff("é😀=1;", "é😀 = 1;");
	assert before.length == 2 && before[0].start == 6;
	const inside = assertDiff("x é😀y z", "x é😀t z");
	assert inside.length == 1 && inside[0].start == 2 && inside[0].end == 9 && inside[0].newText == "é😀t";
}

test "a CRLF break is one token and stays out of an indent change" {
	const edits = assertDiff("a;\r\n\t\tb;\r\n", "a;\r\n\tb;\r\n");
	assert edits.length == 1;
	assert edits[0].start == 4 && edits[0].end == 6 && edits[0].newText == "\t";
	assert assertDiff("a;\r\nb;", "a;\nb;").length == 1;
}

test "texts sharing no token become one replacing edit" {
	const edits = assertDiff("abc", "+");
	assert edits.length == 1 && edits[0].start == 0 && edits[0].end == 3;
}

test "shuffled and repeated tokens still reproduce the target" {
	assertDiff("a b a c a b", "b a c a b a");
	assertDiff("x x x x", "x x");
	assertDiff("1 2 3 4 5 6 7 8", "8 7 6 5 4 3 2 1");
	assertDiff("abcabba", "cbabac");
	assertDiff("f(a, b);\nf(c, d);\n", "f(c, d);\nf(a, b);\n");
}

function pseudoRandomWords(seed: int32, count: int32): string {
	let state = seed;
	let text = "";
	for (let i: int32 = 0; i < count; i += 1) {
		state = (state * 75 + 74) % 65537;
		text += "ab;\n "[(state >> 4) % 5];
		if ((state >> 9) % 3 == 0) text += "c";
	}
	return text;
}

test "generated pairs of texts reproduce the target" {
	for (let seed: int32 = 1; seed <= 300; seed += 1) {
		assertDiff(pseudoRandomWords(seed, seed % 40), pseudoRandomWords(seed * 7 + 3, (seed * 3) % 45));
	}
}
