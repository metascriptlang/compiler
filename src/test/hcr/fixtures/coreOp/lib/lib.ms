export type Dir = "row" | "column";
export interface Style { dir: Dir | null; size: [string, int32] }

export function clearStyle(s: Style): void {
	s.dir = null;
	s.size = ["none", 0];
}

export function sizeOf(s: Style): [string, int32] {
	return s.size;
}

export function dirName(s: Style): string {
	if (s.dir !== null) return s.dir;
	return "none";
}
