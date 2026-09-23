@beforeReload
function quiesce(): void {
	console.log("HCR-ENGINE lifecycle v1: before reload");
}

@afterReload
function resume(): void {
	console.log("HCR-ENGINE lifecycle v1: after reload");
}

export function version(): int32 {
	return 1;
}

export class Probe {
	tag: int32;

	constructor(tag: int32) {
		this.tag = tag;
	}

	scaled(): int32 {
		return this.tag * 10;
	}

	onDestroy(): void {
		console.log(`HCR-ENGINE lifecycle v1: destroy probe ${this.tag}`);
	}
}

export function makeProbe(tag: int32): Probe {
	return new Probe(tag);
}

export function checked(count: int32): int32 {
	if (count < 0) throw new Error("negative count");
	return count;
}
