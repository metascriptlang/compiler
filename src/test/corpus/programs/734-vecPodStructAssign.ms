// @stdout: vec-pod-struct-assign done

// Vec<POD-struct> owns its payload like any other seq: classifyArray must not
// bail to noRcInfo just because the element has no managed fields — Nim lifts
// =destroy/=copy for every tySequence (liftdestructors fillSeqOp). The generic
// msArray macros size the stride from the per-type C array, so the primitive
// payload path is exact for POD elements.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

struct Pod { x: int32; y: int32; }

function assignDetach(): boolean {
	let a: Vec<Pod> = [{ x: 1, y: 2 }];
	let b: Vec<Pod> = a;
	b[0].x = 9;
	return a[0].x === 1 && b[0].x === 9;
}

function pushDetach(): boolean {
	let a: Vec<Pod> = [{ x: 1, y: 2 }];
	let b: Vec<Pod> = a;
	b.push({ x: 3, y: 4 });
	return a.length === 1 && b.length === 2;
}

function reassignDetach(): boolean {
	let a: Vec<Pod> = [{ x: 1, y: 2 }];
	let b: Vec<Pod> = [{ x: 5, y: 6 }];
	b = a;
	a[0].y = 7;
	return b[0].y === 2;
}

function structField(): boolean {
	let a: Vec<Pod> = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
	let b: Vec<Pod> = a;
	b[1].y = 9;
	return a[1].y === 4 && b[1].y === 9 && a[0].x === 1;
}

function main(): void {
	let ok = true;
	ok = check("assignDetach", assignDetach()) && ok;
	ok = check("pushDetach", pushDetach()) && ok;
	ok = check("reassignDetach", reassignDetach()) && ok;
	ok = check("structField", structField()) && ok;
	if (ok) { console.log("vec-pod-struct-assign done"); }
}

main();
