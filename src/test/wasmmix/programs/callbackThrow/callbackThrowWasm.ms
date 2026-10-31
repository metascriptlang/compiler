let finals = 0;

@wasm
export function guarded(value: int32, f: (x: int32) => int32): int32 {
	try {
		return f(value) + 1;
	} finally {
		finals = finals + 1;
	}
}

@wasm
export function finalsRun(): int32 {
	return finals;
}

@wasm
export function recover(label: string, f: (s: string) => int32): string {
	return `ok ${f(label)}`;
}
