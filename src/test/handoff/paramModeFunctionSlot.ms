import { checkProjectDiagnostics } from "../helpers";

function refused(source: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

const viaVal = "function viaVal(f: (x: int32) => void): void { let v: int32 = 1; f(v); }\n";
const viaRef = "function viaRef(f: (ref x: int32) => void): void { let v: int32 = 1; f(v); }\n";
const byRef = "'(ref x: int32) => void' takes 'x' by reference, but the expected '(x: int32) => void' passes it by value";
const byVal = "'(x: int32) => void' takes 'x' by value, but the expected '(ref x: int32) => void' passes it by reference";

test "paramModeFunctionSlot: a function taking a parameter by reference does not fill a by-value function slot" {
	assert refused(viaVal + "function bump(ref x: int32): void { x += 1; }\nviaVal(bump);", byRef) == 1;
	assert refused("function bump(ref x: int32): void { x += 1; }\nconst g: (x: int32) => void = bump;", byRef) == 1;
	assert refused(viaVal + "class K { static bump(ref x: int32): void { x += 1; } }\nviaVal(K.bump);", byRef) == 1;
	assert refused(viaVal + "class K { k: int32 = 1; bump(ref x: int32): void { x += this.k; } }\nviaVal(new K().bump);", byRef) == 1;
	assert refused("class P { n: int32 = 0; }\nfunction setP(out p: P): void { p = new P(); }\nfunction viaVal(f: (p: P) => void): void { f(new P()); }\nviaVal(setP);", "takes 'p' as 'out', but the expected '(p: P) => void' passes it by value") == 1;
}

test "paramModeFunctionSlot: a by-value function does not fill a by-reference function slot" {
	assert refused(viaRef + "function show(x: int32): void { console.log(x); }\nviaRef(show);", byVal) == 1;
	assert refused(viaRef + "viaRef((x: int32) => { console.log(x); });", byVal) == 1;
	assert refused(viaRef + "class K { static show(x: int32): void { console.log(x); } }\nviaRef(K.show);", byVal) == 1;
}

test "paramModeFunctionSlot: matching modes fill the slot" {
	assert refused(viaRef + "function bump(ref x: int32): void { x += 1; }\nviaRef(bump);", "mismatch") == 0;
	assert refused("function fill(out x: int32): void { x = 7; }\nfunction viaOut(f: (out x: int32) => void): void { let v: int32 = 0; f(out v); }\nviaOut(fill);", "mismatch") == 0;
	assert refused(viaVal + "viaVal((x: int32) => { console.log(x); });", "mismatch") == 0;
}
