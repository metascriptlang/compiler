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
	line: int32;
	col: int32;
	message: string;
}

export function makeDiag(
	severity: DiagSeverity,
	file: string,
	line: int32,
	col: int32,
	message: string
): Diagnostic {
	return { severity, file, line, col, message };
}
