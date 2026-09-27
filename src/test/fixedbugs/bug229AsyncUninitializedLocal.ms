// Symptom: in an async function, `let x: int32; if (c) { x = await … } else { x = 7; } return x;`
//   returned 0 on C: the branch that ran before any await wrote a copy, not the variable. A string
//   came back empty, a struct zeroed, and a class reference null.
// Root cause: generatorLower convertDeclsToAssigns turned only initialized declarations of lifted
//   locals into assignments; `let x: T;` stayed a declaration and shadowed the state-machine field.
// Fix: an uninitialized lifted declaration becomes `x = default(T)`, a typed null codegen emits as
//   the zero value of T.
// Corpus sibling: src/test/corpus/programs/424-asyncUninitializedLocal.ms runs the same shapes through every lane.

struct Point229 { x: int32; y: int32; }

class Tag229 {
	name: string;
	constructor(name: string) { this.name = name; }
}

async function val229(v: int32): Promise<int32> {
	return v;
}

async function pickInt229(c: boolean): Promise<int32> {
	let x: int32;
	if (c) {
		const v = await val229(1);
		x = v;
	} else {
		x = 7;
	}
	return x;
}

async function pickString229(c: boolean): Promise<string> {
	let s: string;
	if (c) {
		const v = await val229(1);
		s = `n${v}`;
	} else {
		s = "seven";
	}
	return s;
}

async function pickPoint229(c: boolean): Promise<Point229> {
	let p: Point229;
	if (c) {
		const v = await val229(1);
		p = { x: v, y: v };
	} else {
		p = { x: 7, y: 8 };
	}
	return p;
}

async function pickTag229(c: boolean): Promise<Tag229> {
	let t: Tag229;
	if (c) {
		const v = await val229(1);
		t = new Tag229(`n${v}`);
	} else {
		t = new Tag229("seven");
	}
	return t;
}

test "bug229: an uninitialized async int32 local keeps the value written before the first await" {
	assert await pickInt229(false) == 7;
	assert await pickInt229(true) == 1;
}

test "bug229: an uninitialized async string local keeps the value written before the first await" {
	assert await pickString229(false) == "seven";
	assert await pickString229(true) == "n1";
}

test "bug229: an uninitialized async struct local keeps the value written before the first await" {
	const p = await pickPoint229(false);
	assert p.x == 7 && p.y == 8;
}

test "bug229: an uninitialized async class local keeps the value written before the first await" {
	const t = await pickTag229(false);
	assert t.name == "seven";
}
