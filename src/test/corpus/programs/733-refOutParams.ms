// @stdout: ref-out-params done
// @skip-js: Var params need a JS write-back strategy (no address-of on JS)

// out/ref params lower to TypeKind.Var → T* in C. The chain that had to agree:
// checkExprPass types OutExpr as its inner arg (not the Inferred sentinel), the
// lvalue validator and codegen isLvalueNode see through OutExpr, paramReassignLower
// never shadows Var params (the shadow silently dropped the write-back), and
// identifier READS of a Var param auto-deref (reference parity: tyVar use).

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

struct Pt2 { x: int32; y: int32; }
struct Box { val: int32; }

function setInt(out v: int32): void { v = 42; }
function setPt(out p: Pt2): void { p = { x: 7, y: 8 }; }
function setStr(out s: string): void { s = "written"; }
function bumpRef(ref v: int32): void { v = v + 1; }
function bumpOut(out v: int32): void { v = v + 1; }
function inner(ref v: int32): void { v = v + 1; }
function outer(ref v: int32): void { inner(v); inner(v); }

function outInt(): boolean {
	let a: int32 = 0;
	setInt(out a);
	return a === 42;
}

function outStruct(): boolean {
	let p: Pt2 = { x: 0, y: 0 };
	setPt(out p);
	return p.x === 7 && p.y === 8;
}

function outString(): boolean {
	let s: string = "orig";
	setStr(out s);
	return s === "written";
}

function refBareReadWrite(): boolean {
	let b: int32 = 10;
	bumpRef(b);
	return b === 11;
}

function outReadWrite(): boolean {
	let b: int32 = 10;
	bumpOut(out b);
	return b === 11;
}

function memberLvalue(): boolean {
	let b: Box = { val: 0 };
	setInt(out b.val);
	return b.val === 42;
}

function elemLvalue(): boolean {
	let arr: Vec<int32> = [0, 0];
	setInt(out arr[1]);
	return arr[1] === 42;
}

function refForwarding(): boolean {
	let x: int32 = 0;
	outer(x);
	return x === 2;
}

function main(): void {
	let ok = true;
	ok = check("outInt", outInt()) && ok;
	ok = check("outStruct", outStruct()) && ok;
	ok = check("outString", outString()) && ok;
	ok = check("refBareReadWrite", refBareReadWrite()) && ok;
	ok = check("outReadWrite", outReadWrite()) && ok;
	ok = check("memberLvalue", memberLvalue()) && ok;
	ok = check("elemLvalue", elemLvalue()) && ok;
	ok = check("refForwarding", refForwarding()) && ok;
	if (ok) { console.log("ref-out-params done"); }
}

main();
