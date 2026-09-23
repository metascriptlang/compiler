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

export function checked(count: int32): int32 {
	if (count < 0) throw new Error("negative count");
	return count;
}
