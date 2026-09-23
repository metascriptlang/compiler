@beforeReload
function quiesce(): void {
	console.log("HCR-ENGINE lifecycle v2: before reload");
}

@afterReload
function resume(): void {
	console.log("HCR-ENGINE lifecycle v2: after reload");
	throw new Error("resume failed");
}

export function version(): int32 {
	return 2;
}

export class Probe {
	tag: int32;

	constructor(tag: int32) {
		this.tag = tag;
	}

	onDestroy(): void {
		console.log(`HCR-ENGINE lifecycle v2: destroy probe ${this.tag}`);
	}
}

export function makeProbe(tag: int32): Probe {
	return new Probe(tag);
}

export function checked(count: int32): int32 {
	if (count < 0) throw new Error("negative count");
	return count;
}
