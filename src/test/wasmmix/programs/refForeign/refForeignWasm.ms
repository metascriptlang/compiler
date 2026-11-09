export enum Level { Low = 1, High = 2 }

@wasm
export function bump(ref n: int32): int32 {
	n = n + 1;
	return n;
}

@wasm
export function fill(out lvl: Level, out s: string): void {
	lvl = Level.High;
	s = "set";
}
