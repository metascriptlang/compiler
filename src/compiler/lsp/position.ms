// LSP positions: a character counts UTF-16 code units, a checker column counts bytes from 1.
// A function taking a LineIndex serves a handler that converts many positions of one source;
// the one taking only the source builds the index for a single conversion.

import { LineIndex, lineStart } from "../../utils/sourceLines";

function lineText(lines: LineIndex, source: string, line: int32): string {
	const text = source.byteSlice(lines.lineStart(line), lines.lineStart(line + 1));
	const terminator = text.endsWith("\r\n") ? 2 : text.endsWith("\n") ? 1 : 0;
	return text.byteSlice(0, text.byteLength - terminator);
}

export function lspByteColumnIn(lines: LineIndex, source: string, line: int32, character: int32): int32 {
	const text = lineText(lines, source, line);
	const unit = character < text.length ? character : text.length;
	const previous = text.charCodeAt(unit - 1);
	const current = text.charCodeAt(unit);
	const inside = previous >= 0xD800 && previous <= 0xDBFF && current >= 0xDC00 && current <= 0xDFFF;
	return text.slice(0, inside ? unit - 1 : unit).byteLength + 1;
}

export function lspByteColumn(source: string, line: int32, character: int32): int32 {
	return lspByteColumnIn(LineIndex.build(source), source, line, character);
}

export function lspCharacterIn(lines: LineIndex, source: string, line: int32, column: int32): int32 {
	const text = lineText(lines, source, line);
	const end = column > 0 ? column - 1 : 0;
	return text.byteSlice(0, end < text.byteLength ? end : text.byteLength).length;
}

export function lspCharacter(source: string, line: int32, column: int32): int32 {
	return lspCharacterIn(LineIndex.build(source), source, line, column);
}
