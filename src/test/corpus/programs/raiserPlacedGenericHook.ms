// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: drop a
// @stdout: drop 1
// @stdout: drop 2
// @stdout: drop b
struct Slot<T> {
	value: T;
}

function onDestroy<T>(this s: Slot<T>): void {
	console.log(`drop ${s.value}`);
}

function scope(): void {
	const n: Slot<int32> = { value: 1 };
	const s: Slot<string> = { value: "a" };
}

function scopeAgain(): void {
	const s: Slot<string> = { value: "b" };
	const n: Slot<int32> = { value: 2 };
}

scope();
scopeAgain();
