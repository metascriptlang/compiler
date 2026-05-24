// Baseline scenarios — verify classify.ms routes CORRECTLY for element
// types that have always worked. These must stay GREEN through all of
// Phase G's changes (G2-G5). If any of these go RED, we've broken a
// previously-working path.

import { firstArrayDestroyEmitted, compilesCleanly } from "../helpers";

test "baseline: number array → msArrayDestroy (primitive path)" {
	const src = `
function main(): void {
	const xs: number[] = [1, 2, 3];
	console.log(xs.length.toString());
}
main();
`;
	assert compilesCleanly(src);
	assert firstArrayDestroyEmitted(src) === "msArrayDestroy(";
}

test "baseline: string array → msArrayStringDestroy" {
	const src = `
function main(): void {
	const xs: string[] = ["a", "b"];
	console.log(xs.length.toString());
}
main();
`;
	assert compilesCleanly(src);
	assert firstArrayDestroyEmitted(src) === "msArrayStringDestroy(";
}

test "baseline: ref-to-interface array → msArrayRefDestroy" {
	const src = `
interface Box { value: int32; }
function main(): void {
	const xs: Box[] = [{ value: 1 }, { value: 2 }];
	console.log(xs.length.toString());
}
main();
`;
	assert compilesCleanly(src);
	const destroy = firstArrayDestroyEmitted(src);
	// interface = reference type, routes through Ref-array path
	assert destroy === "msArrayRefDestroy(";
}

test "baseline: int32 array → msArrayDestroy" {
	const src = `
function main(): void {
	const xs: int32[] = [1 as int32, 2 as int32];
	console.log(xs.length.toString());
}
main();
`;
	assert compilesCleanly(src);
	assert firstArrayDestroyEmitted(src) === "msArrayDestroy(";
}
