// Source-text positions: lines are 1-based, offsets are bytes. The line start offsets are computed
// once per source, so a lookup does not rescan the text.

export struct LineIndex {
	starts: int32[];
	length: int32;
}

export function build(this typeof LineIndex, source: string): LineIndex {
	const starts: int32[] = [0];
	for (let i: int32 = 0; i < source.byteLength; i++) {
		if (source.byteAt(i) == "\n".code) starts.push(i + 1);
	}
	return { starts, length: source.byteLength };
}

// Offset of the first byte of `line`; a line past the last one starts at the end of the source.
export function lineStart(this ix: LineIndex, line: int32): int32 {
	if (line <= 1) return 0;
	return line <= ix.starts.length ? ix.starts[line - 1] : ix.length;
}

export function lineOf(this ix: LineIndex, offset: int32): int32 {
	let low: int32 = 0;
	let high: int32 = ix.starts.length - 1;
	while (low < high) {
		const mid = (low + high + 1) >> 1;
		if (ix.starts[mid] <= offset) low = mid;
		else high = mid - 1;
	}
	return low + 1;
}

// One lookup stops at its line instead of indexing the whole source; use a LineIndex for several.
export function lineOffset(source: string, line: int32): int32 {
	let current = 1;
	let pos = 0;
	while (pos < source.byteLength && current < line) {
		if (source.byteAt(pos) == "\n".code) current += 1;
		pos += 1;
	}
	return pos;
}

test "a line starts after the newline that ends the one before" {
	const ix = LineIndex.build("ab\ncd\n\nx");
	assert ix.lineStart(1) == 0;
	assert ix.lineStart(2) == 3;
	assert ix.lineStart(3) == 6;
	assert ix.lineStart(4) == 7;
}

test "a line past the last starts at the end, and a line below the first starts at 0" {
	const ix = LineIndex.build("ab\ncd");
	assert ix.lineStart(3) == 5;
	assert ix.lineStart(99) == 5;
	assert ix.lineStart(0) == 0;
	assert ix.lineStart(-4) == 0;
}

test "a trailing newline opens an empty last line at the end" {
	const ix = LineIndex.build("ab\n");
	assert ix.lineStart(2) == 3;
	assert ix.lineOf(3) == 2;
}

test "an empty source has one line starting at 0" {
	const ix = LineIndex.build("");
	assert ix.lineStart(1) == 0;
	assert ix.lineStart(2) == 0;
	assert ix.lineOf(0) == 1;
}

test "the line of an offset counts the newlines before it" {
	const ix = LineIndex.build("ab\ncd\n\nx");
	assert ix.lineOf(0) == 1;
	assert ix.lineOf(2) == 1;
	assert ix.lineOf(3) == 2;
	assert ix.lineOf(5) == 2;
	assert ix.lineOf(6) == 3;
	assert ix.lineOf(7) == 4;
	assert ix.lineOf(8) == 4;
}

test "lineOffset answers what the index answers for every line, in range and beyond" {
	const sources = ["", "\n", "ab", "ab\n", "ab\ncd", "\n\nx\n", "a\r\nb\r\n\u{1F600}"];
	for (const source of sources) {
		const ix = LineIndex.build(source);
		for (let line: int32 = -1; line <= ix.starts.length + 2; line++) {
			assert lineOffset(source, line) == ix.lineStart(line);
		}
	}
}
