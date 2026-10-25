import { lspByteColumn, lspCharacter } from "../position";

// row: [line, character, column, 1 when column maps back to character]
// returns the index of the first row that disagrees, or -1
function firstBadRow(source: string, rows: int32[][]): int32 {
	for (let i = 0; i < rows.length; i++) {
		const row = rows[i];
		if (lspByteColumn(source, row[0], row[1]) != row[2]) { return i; }
		if (row[3] == 1 && lspCharacter(source, row[0], row[2]) != row[1]) { return i; }
	}
	return -1;
}

test "ascii positions" {
	assert firstBadRow("abc", [[1, 0, 1, 1], [1, 1, 2, 1], [1, 2, 3, 1], [1, 3, 4, 1]]) == -1;
}

test "two byte one unit" {
	assert firstBadRow("aéb", [[1, 0, 1, 1], [1, 1, 2, 1], [1, 2, 4, 1], [1, 3, 5, 1]]) == -1;
}

test "three byte one unit" {
	assert firstBadRow("a日b", [[1, 0, 1, 1], [1, 1, 2, 1], [1, 2, 5, 1], [1, 3, 6, 1]]) == -1;
}

test "four byte two units and split pair" {
	assert firstBadRow("a\u{1F600}b", [
		[1, 0, 1, 1], [1, 1, 2, 1], [1, 2, 2, 0], [1, 3, 6, 1], [1, 4, 7, 1],
	]) == -1;
}

test "later lines after LF" {
	assert firstBadRow("ab\ncé\n日x", [
		[1, 0, 1, 1], [1, 2, 3, 1], [1, 3, 3, 0],
		[2, 0, 1, 1], [2, 1, 2, 1], [2, 2, 4, 1], [2, 3, 4, 0],
		[3, 0, 1, 1], [3, 1, 4, 1], [3, 2, 5, 1],
	]) == -1;
}

test "later lines after CRLF exclude the line terminator" {
	assert firstBadRow("a\r\nb\u{1F600}\r\nc", [
		[1, 0, 1, 1], [1, 1, 2, 1], [1, 2, 2, 0], [1, 3, 2, 0],
		[2, 0, 1, 1], [2, 1, 2, 1], [2, 2, 2, 0], [2, 3, 6, 1], [2, 4, 6, 0], [2, 5, 6, 0],
		[3, 0, 1, 1], [3, 1, 2, 1],
	]) == -1;
}

test "character beyond line end" {
	assert firstBadRow("ab\ncd", [[1, 10, 3, 0], [2, 5, 3, 0], [2, 99, 3, 0]]) == -1;
	assert lspCharacter("ab\ncd", 1, 9) == 2;
	assert lspCharacter("ab\ncd", 2, 99) == 2;
}

test "empty source" {
	assert firstBadRow("", [[1, 0, 1, 1], [1, 5, 1, 0]]) == -1;
	assert lspCharacter("", 1, 9) == 0;
}

test "line beyond last line" {
	assert firstBadRow("ab\ncd", [[5, 0, 1, 0], [5, 3, 1, 0]]) == -1;
	assert lspCharacter("ab\ncd", 5, 4) == 0;
}

test "one line with a two, three and four byte character" {
	assert firstBadRow("a\u{E9}\u{65E5}\u{1F600}z", [
		[1, 0, 1, 1], [1, 1, 2, 1], [1, 2, 4, 1], [1, 3, 7, 1], [1, 4, 7, 0], [1, 5, 11, 1], [1, 6, 12, 1],
	]) == -1;
}

test "last line without a trailing newline" {
	assert firstBadRow("ab\nc\u{1F600}\u{E9}", [
		[1, 2, 3, 1],
		[2, 0, 1, 1], [2, 1, 2, 1], [2, 2, 2, 0], [2, 3, 6, 1], [2, 4, 8, 1], [2, 9, 8, 0],
	]) == -1;
}
