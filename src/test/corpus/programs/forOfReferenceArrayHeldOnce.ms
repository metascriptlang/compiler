// @stdout: rebound 1,2,3, 1 | field 1,2,3, 1 | index 1,2,3, 1 | written 1,2,30, | continued 1,raised | generated raised
// note: a for-of over a T[] reads the array reference once, as TypeScript does, and checks the length after each element, as Nim's items does (NIM-REF TR-26). Rebinding the variable, field or slot that held the array lets the loop finish the array it started, where the lowering used to re-read the path and raise or mix in the new array; a write to an element is seen. A continue or a yield in the body still reaches the length check.

class Holder { xs: number[] = []; }

function rebound(): string {
	let xs: number[] = [1, 2, 3];
	let seen = "";
	for (const x of xs) {
		seen = seen + String(x) + ",";
		xs = [8];
	}
	return `rebound ${seen} ${xs.length}`;
}

function field(): string {
	const h = new Holder();
	h.xs = [1, 2, 3];
	let seen = "";
	for (const x of h.xs) {
		seen = seen + String(x) + ",";
		h.xs = [8];
	}
	return `field ${seen} ${h.xs.length}`;
}

function index(): string {
	const g: number[][] = [[1, 2, 3]];
	let seen = "";
	for (const x of g[0]) {
		seen = seen + String(x) + ",";
		g[0] = [8];
	}
	return `index ${seen} ${g[0].length}`;
}

function written(): string {
	const xs: number[] = [1, 2, 3];
	let seen = "";
	for (const x of xs) {
		seen = seen + String(x) + ",";
		xs[2] = 30;
	}
	return `written ${seen}`;
}

function continued(): string {
	const xs: number[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of xs) {
			seen = seen + String(x) + ",";
			if (x == 1) {
				xs.push(4);
				continue;
			}
		}
	} catch (e) {
		return `continued ${seen}raised`;
	}
	return `continued ${seen}finished`;
}

function* evens(xs: number[]): Iterator<number> {
	for (const x of xs) {
		if (x == 1) {
			xs.push(5);
			continue;
		}
		yield x;
	}
}

function generated(): string {
	let seen = "";
	try {
		for (const x of evens([1, 2, 3])) seen = seen + String(x) + ",";
	} catch (e) {
		return `generated ${seen}raised`;
	}
	return `generated ${seen}finished`;
}

console.log(`${rebound()} | ${field()} | ${index()} | ${written()} | ${continued()} | ${generated()}`);
