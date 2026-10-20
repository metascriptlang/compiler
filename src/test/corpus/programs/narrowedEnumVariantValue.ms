// @stdout: eq={"kind":"A","r":"round"} show={"kind":"A","r":"round"} kind=A copy=round,A | ne={"kind":"B","w":"wide"} show={"kind":"B","w":"wide"} kind=B copy=wide,B | tail={"kind":"B","w":"wide"} | open={"kind":"Open","n":7} arr=3,Open | plain={"kind":"B","w":"wide"} plainKind=B
// note: a match-type variant narrowed by a guard keeps its discriminator when used as a whole value, as the reference TypeScript types the narrowed constituent with its kind property and as the object variant keeps its discriminator field. The guard is == and !=, the value is serialized, passed to a generic, copied and read for its kind. The discriminator is an enum member here and a field of every variant, as it is for a boolean one; a payload without a counted member and a TS-written union of enum-literal objects meet the same value rules.

enum K { A, B }
enum Q { Open, Shut }

type Shape = match (kind: K) {
	K.A => { r: string },
	K.B => { w: string },
};

type Gate = match (kind: Q) {
	Q.Open => { n: int32 },
	Q.Shut => { why: string },
};

type Plain = { kind: K.A, r: string } | { kind: K.B, w: string };

function makeShape(a: boolean): Shape {
	if (a) return { kind: K.A, r: "round" };
	return { kind: K.B, w: "wide" };
}

function makeGate(open: boolean): Gate {
	if (open) return { kind: Q.Open, n: 7 };
	return { kind: Q.Shut, why: "late" };
}

function makePlain(a: boolean): Plain {
	if (a) return { kind: K.A, r: "round" };
	return { kind: K.B, w: "wide" };
}

function nameOf(k: K): string {
	return match (k) { K.A => "A", K.B => "B" };
}

function gateName(k: Q): string {
	return match (k) { Q.Open => "Open", Q.Shut => "Shut" };
}

function show<T>(x: T): string {
	return JSON.stringify(x);
}

function main(): void {
	const a = makeShape(true);
	let eq = "";
	if (a.kind == K.A) {
		const c = a;
		eq = `eq=${JSON.stringify(a)} show=${show(a)} kind=${nameOf(a.kind)} copy=${c.r},${nameOf(c.kind)}`;
	}
	const b = makeShape(false);
	let ne = "";
	if (b.kind != K.A) {
		const c = b;
		ne = `ne=${JSON.stringify(b)} show=${show(b)} kind=${nameOf(b.kind)} copy=${c.w},${nameOf(c.kind)}`;
	}
	let tail = "";
	if (b.kind == K.A) {
		tail = "wrong";
	} else {
		tail = `tail=${show(b)}`;
	}
	const g = makeGate(true);
	const gates: Gate[] = [g, makeGate(false), g];
	let open = "";
	if (g.kind == Q.Open) {
		open = `open=${show(g)} arr=${gates.length},${gateName(gates[0].kind)}`;
	}
	const p = makePlain(false);
	let plain = "";
	if (p.kind != K.A) {
		plain = `plain=${show(p)} plainKind=${nameOf(p.kind)}`;
	}
	console.log(`${eq} | ${ne} | ${tail} | ${open} | ${plain}`);
}

main();
