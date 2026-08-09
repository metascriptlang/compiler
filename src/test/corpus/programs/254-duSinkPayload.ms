// Parity program — the payload must survive a DU `=sink`. The union sink hook
// destroys the old variant and copies the discriminant; if it stops there the
// new variant's FIELDS are never transferred, so the value silently keeps the
// old branch's bytes (or zeros). Interface variants are the shape that breaks:
// they are Ref<Struct>, so the per-variant field walk has to peel the Ref the
// way the destroy/copy dispatch already does.
//
// Every cell here is a re-assignment or an assignment into an already-declared
// local — the positions that route through the sink hook rather than through
// NRVO. The JS lane is the spec: objects carry their fields, so js was correct
// while all three C lanes agreed on the wrong answer (which is why this needs
// to be a parity program, not an @stdout one).

interface Alpha { kind: "alpha"; label: string; count: int32; }
interface Beta { kind: "beta"; label: string; ratio: float64; }
type Shape = Alpha | Beta;

function mkAlpha(n: int32): Alpha {
	return { kind: "alpha", label: "a-" + n.toString(), count: n };
}

function mkBeta(n: int32): Beta {
	return { kind: "beta", label: "b-" + n.toString(), ratio: 0.5 };
}

function describe(s: Shape): string {
	if (s.kind === "alpha") {
		return "alpha/" + s.label + "/" + s.count.toString();
	}
	return "beta/" + s.label + "/" + s.ratio.toString();
}

function main(): void {
	// 1. init then re-assign to the OTHER variant — the tag changes, so the
	//    payload must come with it.
	let s: Shape = mkAlpha(1);
	console.log("1 " + describe(s));
	s = mkBeta(2);
	console.log("2 " + describe(s));

	// 2. re-assign within the SAME variant — old fields must be released and
	//    replaced, not kept.
	s = mkBeta(3);
	console.log("3 " + describe(s));
	s = mkAlpha(4);
	console.log("4 " + describe(s));

	// 3. assignment into a local declared before the value exists (the JSON
	//    decode shape: declare, then fill inside a branch).
	let t: Shape = mkAlpha(0);
	if (s.kind === "alpha") {
		t = mkBeta(5);
	}
	console.log("5 " + describe(t));

	// 4. churn so the SAN lane sees real destroy traffic on both variants.
	let flips = 0;
	for (let i = 0; i < 20000; i += 1) {
		s = i % 2 === 0 ? mkAlpha(i) : mkBeta(i);
		if (s.kind === "alpha") {
			flips += 1;
		}
	}
	console.log("6 flips=" + flips.toString() + " last=" + describe(s));
}

main();
