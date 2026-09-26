// nim-guard: at() hands its caller an owned copy of the element
//
// INVARIANT (injectdestructors.nim:1224 moveOrCopy: a call result is sunk into its
//   destination and destroyed by the caller; :1242 a proc returning T whose body reads
//   s[j] copies it, `nim c --expandArc:at` prints `=copy(result, s[j])`): destroying
//   the result of arr.at(i) never finalizes the element the array still holds.
// NIM-REF: SAME, no entry (at<T> is an ordinary proc returning T).
//
// RED MEANS: at() returns the stored element without a copy again, so the caller's
//   destroy and the array's destroy both finalize it (a class or closure env shows
//   DOUBLE-DESTROY, a string or struct corrupts the heap). Run /trace-nim on at<T>
//   (std/core/array/index.cms) and the element type the ledger names.
// GUARD-BALANCE Holder
// GUARD-JS

struct Named {
	name: string;
	n: int32;
}

class Holder {
	rows: string[][] = [];
}

function strings(): int32 {
	let n: int32 = 0;
	for (let k: int32 = 0; k < 200; k++) {
		const ss: string[] = ["a" + k.toString(), "b"];
		const x = ss.at(0);
		const y = ss.at(-1);
		n = n + x.length + y.length;
	}
	return n;
}

function structs(): int32 {
	let n: int32 = 0;
	for (let k: int32 = 0; k < 200; k++) {
		const xs: Named[] = [{ name: "a" + k.toString(), n: 1 }, { name: "b", n: 2 }];
		const x = xs.at(0);
		n = n + x.name.length + xs.at(-1).n;
	}
	return n;
}

function classes(): int32 {
	let n: int32 = 0;
	for (let k: int32 = 0; k < 200; k++) {
		const cs: Holder[] = [new Holder(), new Holder()];
		const c = cs.at(0);
		c.rows.push(["r"]);
		n = n + c.rows.length + cs.at(-1).rows.length;
	}
	return n;
}

function closures(): int32 {
	let n: int32 = 0;
	for (let k: int32 = 0; k < 200; k++) {
		const h = new Holder();
		const fs: (() => int32)[] = [() => h.rows.length as int32 + k, () => 2];
		const f = fs.at(0);
		n = n + f() + fs.at(-1)();
	}
	return n;
}

function nestedNumbers(): int32 {
	let n: int32 = 0;
	for (let k: int32 = 0; k < 200; k++) {
		const n2: int32[][] = [[1], [2, 3]];
		const y = n2.at(0);
		n = n + y.length + n2.at(-1).length;
	}
	return n;
}

function nestedStringsInField(): int32 {
	let n: int32 = 0;
	for (let k: int32 = 0; k < 200; k++) {
		const h = new Holder();
		h.rows.push(["a"]);
		h.rows.push(["b", "c" + k.toString()]);
		const r = h.rows.at(-1);
		n = n + r.length + r.at(1).length;
	}
	return n;
}

console.log(strings(), structs(), classes(), closures(), nestedNumbers(), nestedStringsInField());
console.log("GUARD-OK");
