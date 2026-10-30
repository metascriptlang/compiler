// A view of an inline Vec receiver does not become a counted array
//
// INVARIANT: sort and reverse return a view of their receiver; when the receiver is a Vec place,
//   the view has the Vec's own type, so storing it where a T[] is owned is refused as any Vec is.
//
// WHAT IT CATCHES: a sorted Vec field stored into an array field, returned as an array, or pushed.
//
// RED MEANS: one of the shapes compiled, and a pointer with no count header was counted as an array.
//   A view read in place and a counted array's own sort still compile.
//
// GUARD-JS
// GUARD-CHECK-FAIL is not assignable to type 'number[]'

class K {
	x: number[] = [];
	v: Vec<float64> = [2.0, 1.0];
}

function toField(k: K): void {
	k.x = k.v.sort(); // GUARD-REFUSED
}

function back(): number[] {
	let v: Vec<float64> = [2.0, 1.0];
	return v.sort(); // GUARD-REFUSED
}

function pushIt(out: number[][]): void {
	let v: Vec<float64> = [2.0, 1.0];
	out.push(v.reverse()); // GUARD-REFUSED
}

function readInPlace(k: K): number {
	const s = k.v.sort();
	return s[0];
}

function counted(k: K): void {
	const a: number[] = [2.0, 1.0];
	k.x = a.sort();
}

const k = new K();
toField(k);
console.log(`${back().length} ${readInPlace(k)}`);
counted(k);
pushIt([]);
