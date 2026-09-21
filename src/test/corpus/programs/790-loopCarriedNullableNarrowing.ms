// Parity program — a nullable local reassigned inside a loop and read at the
// loop head, before the reassignment the checker has not visited yet: the
// narrowed read must see the value carried over from the previous iteration,
// on both backends, in a concat, in a local and through the loop forms that
// differ in how the back-edge is bound.
//
// @stdout: concat 'a'|local 'a'|cstyle 'a'|whileLoop 'a'|afterLoop 'b'|straight 'a'
// @exit: 0

class S {
	name: string;
	constructor(n: string) { this.name = n; }
}

function loopConcat(xs: S[]): string {
	let found: S | null = null;
	for (const x of xs) {
		if (found != null) return "'" + found.name + "'";
		found = x;
	}
	return "none";
}

function loopLocal(xs: S[]): string {
	let found: S | null = null;
	for (const x of xs) {
		if (found != null) {
			const n = found.name;
			return "'" + n + "'";
		}
		found = x;
	}
	return "none";
}

function cstyle(xs: S[]): string {
	let found: S | null = null;
	for (let i = 0; i < xs.length; i = i + 1) {
		if (found != null) return "'" + found.name + "'";
		found = xs[i];
	}
	return "none";
}

function whileLoop(xs: S[]): string {
	let found: S | null = null;
	let i = 0;
	while (i < xs.length) {
		if (found != null) return "'" + found.name + "'";
		found = xs[i];
		i = i + 1;
	}
	return "none";
}

function afterLoop(xs: S[]): string {
	let found: S | null = null;
	for (const x of xs) found = x;
	if (found != null) return "'" + found.name + "'";
	return "none";
}

function straight(a: S): string {
	let found: S | null = null;
	found = a;
	if (found != null) return "'" + found.name + "'";
	return "none";
}

function main(): void {
	const xs = [new S("a"), new S("b")];
	console.log(`concat ${loopConcat(xs)}|local ${loopLocal(xs)}|cstyle ${cstyle(xs)}|whileLoop ${whileLoop(xs)}|afterLoop ${afterLoop(xs)}|straight ${straight(new S("a"))}`);
}

main();
