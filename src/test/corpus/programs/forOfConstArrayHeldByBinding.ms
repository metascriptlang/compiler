// @stdout: alias splice raised after k0,
// @stdout: alias drop owner k0,k1,k2, 3 0
// @stdout: direct drop owner k0,k1,k2, 0
// @stdout: alias push raised after k0,
// @stdout: let rebound k0,k1,k2, 0
// @stdout: awaited k0!k02,k1!k12,
// note: a for-of over a T[] held by a const reads the array through the const, with no temp, while the elements may be borrowed; a body that empties the array, drops its other owner, pushes, or suspends must still see live elements, and a rebound let still iterates the array it started. Each case also runs on the direct field form, which keeps its temp.

class Node {
	kids: Node[] = [];
	tag: string = "";
}

function tree(n: int32): Node {
	const root = new Node();
	root.tag = "root";
	for (let i: int32 = 0; i < n; i++) {
		const kid = new Node();
		kid.tag = "k" + String(i);
		root.kids.push(kid);
	}
	return root;
}

function aliasSplice(): string {
	const n = tree(3);
	const kids = n.kids;
	let seen = "";
	try {
		for (const k of kids) { kids.splice(0, 3); seen = seen + k.tag + ","; }
	} catch (e) {
		return "alias splice raised after " + seen;
	}
	return "alias splice finished " + seen;
}

function directSplice(): string {
	const n = tree(3);
	let seen = "";
	try {
		for (const k of n.kids) { n.kids.splice(0, 3); seen = seen + k.tag + ","; }
	} catch (e) {
		return "direct splice raised after " + seen;
	}
	return "direct splice finished " + seen;
}

function aliasPop(): string {
	const n = tree(1);
	const kids = n.kids;
	let seen = "";
	try {
		for (const k of kids) { kids.pop(); seen = seen + k.tag + ","; }
	} catch (e) {
		return "alias pop raised after " + seen;
	}
	return "alias pop finished " + seen;
}

function directPop(): string {
	const n = tree(1);
	let seen = "";
	try {
		for (const k of n.kids) { n.kids.pop(); seen = seen + k.tag + ","; }
	} catch (e) {
		return "direct pop raised after " + seen;
	}
	return "direct pop finished " + seen;
}

function aliasDropOwner(): string {
	const n = tree(3);
	const kids = n.kids;
	let seen = "";
	for (const k of kids) { n.kids = []; seen = seen + k.tag + ","; }
	return "alias drop owner " + seen + " " + String(kids.length) + " " + String(n.kids.length);
}

function directDropOwner(): string {
	const n = tree(3);
	let seen = "";
	for (const k of n.kids) { n.kids = []; seen = seen + k.tag + ","; }
	return "direct drop owner " + seen + " " + String(n.kids.length);
}

function aliasPush(): string {
	const n = tree(2);
	const kids = n.kids;
	let seen = "";
	try {
		for (const k of kids) { kids.push(new Node()); seen = seen + k.tag + ","; }
	} catch (e) {
		return "alias push raised after " + seen;
	}
	return "alias push finished " + seen;
}

function directPush(): string {
	const n = tree(2);
	let seen = "";
	try {
		for (const k of n.kids) { n.kids.push(new Node()); seen = seen + k.tag + ","; }
	} catch (e) {
		return "direct push raised after " + seen;
	}
	return "direct push finished " + seen;
}

function letRebound(): string {
	const n = tree(3);
	let kids = n.kids;
	let seen = "";
	for (const k of kids) { kids = []; seen = seen + k.tag + ","; }
	return "let rebound " + seen + " " + String(kids.length);
}

function captured(): string {
	const n = tree(3);
	const kids = n.kids;
	let seen = "";
	for (const k of kids) {
		const late = (): string => k.tag + String(kids.length);
		seen = seen + late() + ",";
	}
	return "captured " + seen;
}

function* walk(n: Node): Iterator<string> {
	const kids = n.kids;
	for (const k of kids) {
		yield k.tag;
		n.kids = [];
		yield k.tag + String(kids.length);
	}
}

function generated(): string {
	let seen = "";
	for (const s of walk(tree(2))) seen = seen + s + ",";
	return "generated " + seen;
}

async function tick(s: string): Promise<string> {
	return s + "!";
}

async function awaited(): Promise<string> {
	const n = tree(2);
	const kids = n.kids;
	let seen = "";
	for (const k of kids) {
		const t = await tick(k.tag);
		n.kids = [];
		seen = seen + t + k.tag + String(kids.length) + ",";
	}
	return "awaited " + seen;
}

console.log(aliasSplice());
console.log(directSplice());
console.log(aliasPop());
console.log(directPop());
console.log(aliasDropOwner());
console.log(directDropOwner());
console.log(aliasPush());
console.log(directPush());
console.log(letRebound());
console.log(captured());
console.log(generated());
awaited().then((s: string): void => { console.log(s); });
