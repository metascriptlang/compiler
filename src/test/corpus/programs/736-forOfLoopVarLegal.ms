// @stdout: for-of-loop-var-legal done

// The legal surface around the for-of value-elem mutation ban (guard
// forOfLoopVarMutationCheck): rebinding the loop var is a fresh local on
// both backends, and ref elements (T[]) alias through the copied pointer
// identically on C and JS. Nim bans the rebind too (skForVar), we keep the
// TS surface because a rebind never touches the collection on either
// backend.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

struct LPt { x: int32; y: int32; }

function primRebind(): boolean {
	const v: Vec<int32> = [1, 2];
	let s = 0;
	for (let p of v) { p = p + 10; s = s + p; }
	return s === 23 && v[0] === 1;
}

function structRebind(): boolean {
	const v: Vec<LPt> = [{ x: 1, y: 2 }];
	for (let p of v) { p = { x: 8, y: 8 }; }
	return v[0].x === 1;
}

function refElemIndexWrite(): boolean {
	const v: Vec<int32[]> = [[1, 2]];
	for (const p of v) { p[0] = 5; }
	return v[0][0] === 5;
}

function refElemPush(): boolean {
	const v: Vec<int32[]> = [[1]];
	for (const p of v) { p.push(9); }
	return v[0].length === 2;
}

function structRead(): boolean {
	const v: Vec<LPt> = [{ x: 3, y: 4 }];
	let s = 0;
	for (const p of v) { s = s + p.x + p.y; }
	return s === 7;
}

function main(): void {
	let ok = true;
	ok = check("primRebind", primRebind()) && ok;
	ok = check("structRebind", structRebind()) && ok;
	ok = check("refElemIndexWrite", refElemIndexWrite()) && ok;
	ok = check("refElemPush", refElemPush()) && ok;
	ok = check("structRead", structRead()) && ok;
	if (ok) { console.log("for-of-loop-var-legal done"); }
}

main();
