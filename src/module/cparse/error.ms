// cparse — Diagnostic collection
// Collects diagnostics and continues parsing. A single bad declaration is
// skipped, not fatal.

export enum DiagSeverity {
	Warning,
	Error,
}

export interface Diagnostic {
	severity: DiagSeverity;
	file: string;
	line: number;
	col: number;
	message: string;
}

export function makeDiag(
	severity: DiagSeverity,
	file: string,
	line: number,
	col: number,
	message: string
): Diagnostic {
	return { severity, file, line, col, message };
}

// Comparator for sort-by-source-order.
export function cmpDiag(a: Diagnostic, b: Diagnostic): number {
	if (a.file < b.file) return -1;
	if (a.file > b.file) return 1;
	if (a.line !== b.line) return a.line - b.line;
	if (a.col !== b.col) return a.col - b.col;
	return 0;
}

test "diag sort order" {
	const a = makeDiag(DiagSeverity.Error, "a.h", 5, 1, "m");
	const b = makeDiag(DiagSeverity.Error, "a.h", 10, 1, "m");
	const c = makeDiag(DiagSeverity.Error, "b.h", 1, 1, "m");
	assert cmpDiag(a, b) < 0;
	assert cmpDiag(b, c) < 0;
	assert cmpDiag(a, a) === 0;
}
