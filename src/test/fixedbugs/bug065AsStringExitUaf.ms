// bug065 — asString exit path: returning a built string dangled (UAF)
//
// Symptom:    `function build(): string { const buf: uint8[] = []; …push…;
//             return buf.asString(); }` — the returned string read heap
//             garbage once later allocations reused the freed payload
//             (measured: audit3 probe printed junk after 64 pushes into an
//             unrelated array).
//
// Root cause: @builtin("AsString") lowered to HiddenStdConv + Cursor — a
//             zero-copy BORROW of the array's payload bits. But the OWNED
//             array is destroyed when the builder's scope ends, so the
//             borrow escaping through `return` dangles. Nim's cast moves
//             ownership WITH the value; our Cursor flag only skips destroy
//             on the result, it cannot extend the source's lifetime.
//
// Fix:        asString is now a COPYING kernel (cstrToNimstr shape):
//             the interception is gone and the call reaches the plain
//             extern `msAsString(msUint8Array*)`, which allocates a fresh
//             owned msString via msStringNew. Zero-copy via analyzer
//             last-use move is a later arc (BUGS.md §2 bridge-ownership row).
//             asBytes (string → uint8[]) stays a Cursor borrow — the read
//             path is measured-correct (bug063).

function bug065Build(): string {
	const buf: uint8[] = [];
	let i = 0;
	while (i < 64) {
		buf.push((65 + (i % 26)) as uint8);
		i = i + 1;
	}
	return buf.asString();
}

test "bug065: returned asString survives the builder scope" {
	const s1 = bug065Build();
	const junk: uint8[] = [];
	let j = 0;
	while (j < 64) {
		junk.push(88);
		j = j + 1;
	}
	assert s1.length == 64;
	assert s1.charCodeAt(0) == 65;
	assert s1.charCodeAt(63) == 76;
	assert s1.charCodeAt(25) == 90;
}

// Proven-red shape: growing the source past its cap reallocs the payload
// (freeing the block the borrow pointed at), and the next same-size-class
// allocation reuses that block — the borrowed result then read garbage
// (measured charCodeAt(0) = 50 under the Cursor emission).
test "bug065: asString result survives source realloc and heap reuse" {
	const buf: uint8[] = [];
	buf.push(104);
	buf.push(105);
	const s = buf.asString();
	let k = 0;
	while (k < 200) {
		buf.push(33);
		k = k + 1;
	}
	const spoil = "abc" + "d";
	assert spoil.length == 4;
	assert s.length == 2;
	assert s == "hi";
	assert s.charCodeAt(0) == 104;
}
