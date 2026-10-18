export struct P { n: int32; }
export type Handle = distinct P;

let destroyed: int32 = 0;

export function onDestroy(this h: Handle): void { destroyed += 1; }
export function destroyedCount(): int32 { return destroyed; }
export function mk(): Handle {
	const p: P = { n: 1 };
	return p as Handle;
}
