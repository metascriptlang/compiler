// nim-guard: a call that can raise, ANYWHERE inside a statement, puts the cleanup
// of every enclosing scope in a finally region — so an object alive across the
// raise is released exactly once on the raise path.
//
// INVARIANT (reference injectdestructors):
//   - the call arm sets `needsTry` on the scope being walked whenever the callee
//     can raise (`if canRaise(n[0]): s.needsTry = true`), for every call the walk
//     reaches: statement position, nested operand, condition, initializer.
//   - processScope ORs the flag into the parent at scope close, so a raise in an
//     inner body wraps the OUTER scope's destroys in try/finally too.
//   Here the flag is set by one read-only scan of the statement before it is
//   rewritten (our expression walk is not total: loop cond/init/update, switch
//   discriminant and cursor-decl initializers are never walked), and propagated
//   eagerly to every open scope — same result as the OR at close.
//   NIM-REF: "needsTry is set by scanning the whole statement" — SAME
//   outcome, DIVERGE-INTENTIONAL mechanism.
//
// WHAT IT CATCHES:
//   - the flag decided from the statement's top-level SHAPE (bare call / call
//     initializer / call right-hand side): a raise inside an if/else/loop/match/
//     block/try body, a condition, an operand, an index, a literal field or a
//     constructor argument skipped the owner's destroy — one leak per raise.
//     `assert` lowers to `if (!c) { fail(); }`, so every failing assert leaked
//     every live local of the test.
//
// RED MEANS: needsTry no longer follows raising calls into that statement shape —
//   the FAIL line names the shape (H<Shape>). Run /trace-nim on
//   setNeedsTryIfRaises / processStmt in analyzer/inject.ms.
//
// GUARD-BALANCE HDirect
// GUARD-BALANCE HVarInit
// GUARD-BALANCE HAssign
// GUARD-BALANCE HRcInit
// GUARD-BALANCE HRcAssign
// GUARD-BALANCE HIf
// GUARD-BALANCE HElse
// GUARD-BALANCE HElseIf
// GUARD-BALANCE HWhile
// GUARD-BALANCE HDoWhile
// GUARD-BALANCE HForOf
// GUARD-BALANCE HForC
// GUARD-BALANCE HMatch
// GUARD-BALANCE HMatchExpr
// GUARD-BALANCE HBlock
// GUARD-BALANCE HTryFin
// GUARD-BALANCE HCatchBody
// GUARD-BALANCE HIfCond
// GUARD-BALANCE HWhileCond
// GUARD-BALANCE HForCond
// GUARD-BALANCE HTernary
// GUARD-BALANCE HShortCirc
// GUARD-BALANCE HBinInit
// GUARD-BALANCE HArgNest
// GUARD-BALANCE HMethod
// GUARD-BALANCE HClosure
// GUARD-BALANCE HReturn
// GUARD-BALANCE HSwitchDisc
// GUARD-BALANCE HSwitchCase
// GUARD-BALANCE HForInit
// GUARD-BALANCE HForUpdate
// GUARD-BALANCE HDoCond
// GUARD-BALANCE HIndex
// GUARD-BALANCE HObjLit
// GUARD-BALANCE HNewArg
// GUARD-BALANCE HTemplate
// GUARD-BALANCE HMemberOf
// GUARD-BALANCE HUnary
// GUARD-BALANCE HNestedLoop
// GUARD-BALANCE HAfterHeld

function boom(): void { throw new Error("boom"); }
function boomB(): boolean { throw new Error("boomB"); }
function boomN(): int32 { throw new Error("boomN"); }
function boomS(): string { throw new Error("boomS"); }
class Obj {
	n: int32;
	constructor() { this.n = 1; }
	go(): void { throw new Error("go"); }
}
class HDirect {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeDirect(flag: boolean, k: int32, xs: int32[]): void {
	const h: HDirect = new HDirect("Direct");
	boom();
	console.log("unreached " + h.tag);
}
class HVarInit {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeVarInit(flag: boolean, k: int32, xs: int32[]): void {
	const h: HVarInit = new HVarInit("VarInit");
	const n: int32 = boomN();
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HAssign {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeAssign(flag: boolean, k: int32, xs: int32[]): void {
	const h: HAssign = new HAssign("Assign");
	let n: int32 = 0;
	n = boomN();
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HRcInit {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeRcInit(flag: boolean, k: int32, xs: int32[]): void {
	const h: HRcInit = new HRcInit("RcInit");
	const s: string = boomS();
	console.log(s);
	console.log("unreached " + h.tag);
}
class HRcAssign {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeRcAssign(flag: boolean, k: int32, xs: int32[]): void {
	const h: HRcAssign = new HRcAssign("RcAssign");
	let s: string = "a";
	s = boomS();
	console.log(s);
	console.log("unreached " + h.tag);
}
class HIf {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeIf(flag: boolean, k: int32, xs: int32[]): void {
	const h: HIf = new HIf("If");
	if (flag) { boom(); }
	console.log("unreached " + h.tag);
}
class HElse {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeElse(flag: boolean, k: int32, xs: int32[]): void {
	const h: HElse = new HElse("Else");
	if (!flag) { console.log("no"); } else { boom(); }
	console.log("unreached " + h.tag);
}
class HElseIf {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeElseIf(flag: boolean, k: int32, xs: int32[]): void {
	const h: HElseIf = new HElseIf("ElseIf");
	if (!flag) { console.log("no"); } else if (k == 1) { boom(); }
	console.log("unreached " + h.tag);
}
class HWhile {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeWhile(flag: boolean, k: int32, xs: int32[]): void {
	const h: HWhile = new HWhile("While");
	let i: int32 = 0;
	while (i < 1) { i += 1; boom(); }
	console.log("unreached " + h.tag);
}
class HDoWhile {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeDoWhile(flag: boolean, k: int32, xs: int32[]): void {
	const h: HDoWhile = new HDoWhile("DoWhile");
	let i: int32 = 0;
	do { i += 1; boom(); } while (i < 1);
	console.log("unreached " + h.tag);
}
class HForOf {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeForOf(flag: boolean, k: int32, xs: int32[]): void {
	const h: HForOf = new HForOf("ForOf");
	for (const x of xs) { boom(); }
	console.log("unreached " + h.tag);
}
class HForC {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeForC(flag: boolean, k: int32, xs: int32[]): void {
	const h: HForC = new HForC("ForC");
	for (let i: int32 = 0; i < 1; i += 1) { boom(); }
	console.log("unreached " + h.tag);
}
class HMatch {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeMatch(flag: boolean, k: int32, xs: int32[]): void {
	const h: HMatch = new HMatch("Match");
	match (k) { 1 => { boom(); }, _ => { console.log("no"); } }
	console.log("unreached " + h.tag);
}
class HMatchExpr {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeMatchExpr(flag: boolean, k: int32, xs: int32[]): void {
	const h: HMatchExpr = new HMatchExpr("MatchExpr");
	const n: int32 = match (k) { 1 => boomN(), _ => 0 };
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HBlock {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeBlock(flag: boolean, k: int32, xs: int32[]): void {
	const h: HBlock = new HBlock("Block");
	{ { boom(); } }
	console.log("unreached " + h.tag);
}
class HTryFin {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeTryFin(flag: boolean, k: int32, xs: int32[]): void {
	const h: HTryFin = new HTryFin("TryFin");
	try { boom(); } finally { console.log("fin"); }
	console.log("unreached " + h.tag);
}
class HCatchBody {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeCatchBody(flag: boolean, k: int32, xs: int32[]): void {
	const h: HCatchBody = new HCatchBody("CatchBody");
	try { boom(); } catch (e) { boom(); }
	console.log("unreached " + h.tag);
}
class HIfCond {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeIfCond(flag: boolean, k: int32, xs: int32[]): void {
	const h: HIfCond = new HIfCond("IfCond");
	if (boomB()) { console.log("no"); }
	console.log("unreached " + h.tag);
}
class HWhileCond {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeWhileCond(flag: boolean, k: int32, xs: int32[]): void {
	const h: HWhileCond = new HWhileCond("WhileCond");
	while (boomB()) { console.log("no"); }
	console.log("unreached " + h.tag);
}
class HForCond {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeForCond(flag: boolean, k: int32, xs: int32[]): void {
	const h: HForCond = new HForCond("ForCond");
	for (let i: int32 = 0; boomB(); i += 1) { console.log("no"); }
	console.log("unreached " + h.tag);
}
class HTernary {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeTernary(flag: boolean, k: int32, xs: int32[]): void {
	const h: HTernary = new HTernary("Ternary");
	const n: int32 = flag ? boomN() : 0;
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HShortCirc {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeShortCirc(flag: boolean, k: int32, xs: int32[]): void {
	const h: HShortCirc = new HShortCirc("ShortCirc");
	if (flag && boomB()) { console.log("no"); }
	console.log("unreached " + h.tag);
}
class HBinInit {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeBinInit(flag: boolean, k: int32, xs: int32[]): void {
	const h: HBinInit = new HBinInit("BinInit");
	const n: int32 = 1 + boomN();
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HArgNest {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeArgNest(flag: boolean, k: int32, xs: int32[]): void {
	const h: HArgNest = new HArgNest("ArgNest");
	console.log("no" + boomN());
	console.log("unreached " + h.tag);
}
class HMethod {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeMethod(flag: boolean, k: int32, xs: int32[]): void {
	const h: HMethod = new HMethod("Method");
	const o: Obj = new Obj();
	o.go();
	console.log("unreached " + h.tag);
}
class HClosure {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeClosure(flag: boolean, k: int32, xs: int32[]): void {
	const h: HClosure = new HClosure("Closure");
	const f = (): void => { boom(); };
	f();
	console.log("unreached " + h.tag);
}
class HReturn {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeReturn(flag: boolean, k: int32, xs: int32[]): void {
	const h: HReturn = new HReturn("Return");
	if (flag) { return boom(); }
	console.log("unreached " + h.tag);
}
interface Pt { x: int32; y: int32; }
class Obj2 {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
class HSwitchDisc {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeSwitchDisc(flag: boolean, k: int32, xs: int32[]): void {
	const h: HSwitchDisc = new HSwitchDisc("SwitchDisc");
	switch (boomN()) { case 1: console.log("no"); break; default: console.log("no"); }
	console.log("unreached " + h.tag);
}
class HSwitchCase {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeSwitchCase(flag: boolean, k: int32, xs: int32[]): void {
	const h: HSwitchCase = new HSwitchCase("SwitchCase");
	switch (k) { case 1: boom(); break; default: console.log("no"); }
	console.log("unreached " + h.tag);
}
class HForInit {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeForInit(flag: boolean, k: int32, xs: int32[]): void {
	const h: HForInit = new HForInit("ForInit");
	for (let i: int32 = boomN(); i < 1; i += 1) { console.log("no"); }
	console.log("unreached " + h.tag);
}
class HForUpdate {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeForUpdate(flag: boolean, k: int32, xs: int32[]): void {
	const h: HForUpdate = new HForUpdate("ForUpdate");
	for (let i: int32 = 0; i < 2; i = boomN()) { console.log("once"); }
	console.log("unreached " + h.tag);
}
class HDoCond {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeDoCond(flag: boolean, k: int32, xs: int32[]): void {
	const h: HDoCond = new HDoCond("DoCond");
	do { console.log("once"); } while (boomB());
	console.log("unreached " + h.tag);
}
class HIndex {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeIndex(flag: boolean, k: int32, xs: int32[]): void {
	const h: HIndex = new HIndex("Index");
	const n: int32 = xs[boomN()];
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HObjLit {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeObjLit(flag: boolean, k: int32, xs: int32[]): void {
	const h: HObjLit = new HObjLit("ObjLit");
	const p: Pt = { x: boomN(), y: 1 };
	console.log("no" + p.x);
	console.log("unreached " + h.tag);
}
class HNewArg {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeNewArg(flag: boolean, k: int32, xs: int32[]): void {
	const h: HNewArg = new HNewArg("NewArg");
	const o: Obj2 = new Obj2(boomN());
	console.log("no" + o.n);
	console.log("unreached " + h.tag);
}
class HTemplate {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeTemplate(flag: boolean, k: int32, xs: int32[]): void {
	const h: HTemplate = new HTemplate("Template");
	console.log(`no ${boomN()}`);
	console.log("unreached " + h.tag);
}
class HMemberOf {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeMemberOf(flag: boolean, k: int32, xs: int32[]): void {
	const h: HMemberOf = new HMemberOf("MemberOf");
	const n: int32 = boomS().length;
	console.log("no" + n);
	console.log("unreached " + h.tag);
}
class HUnary {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeUnary(flag: boolean, k: int32, xs: int32[]): void {
	const h: HUnary = new HUnary("Unary");
	if (!boomB()) { console.log("no"); }
	console.log("unreached " + h.tag);
}
class HNestedLoop {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeNestedLoop(flag: boolean, k: int32, xs: int32[]): void {
	const h: HNestedLoop = new HNestedLoop("NestedLoop");
	for (const x of xs) { for (const y of xs) { if (x == y) { boom(); } } }
	console.log("unreached " + h.tag);
}
class HAfterHeld {
	tag: string;
	constructor(t: string) { this.tag = t; }
}
function shapeAfterHeld(flag: boolean, k: int32, xs: int32[]): void {
	const h: HAfterHeld = new HAfterHeld("AfterHeld");
	const h2: HAfterHeld = new HAfterHeld("second");
	if (flag) { boom(); }
	console.log(h2.tag);
	console.log("unreached " + h.tag);
}
function main(): void {
	const xs: int32[] = [1];
	for (let round: int32 = 0; round < 8; round += 1) {
		try { shapeDirect(true, 1, xs); } catch (e) { console.log("caught Direct"); }
		try { shapeVarInit(true, 1, xs); } catch (e) { console.log("caught VarInit"); }
		try { shapeAssign(true, 1, xs); } catch (e) { console.log("caught Assign"); }
		try { shapeRcInit(true, 1, xs); } catch (e) { console.log("caught RcInit"); }
		try { shapeRcAssign(true, 1, xs); } catch (e) { console.log("caught RcAssign"); }
		try { shapeIf(true, 1, xs); } catch (e) { console.log("caught If"); }
		try { shapeElse(true, 1, xs); } catch (e) { console.log("caught Else"); }
		try { shapeElseIf(true, 1, xs); } catch (e) { console.log("caught ElseIf"); }
		try { shapeWhile(true, 1, xs); } catch (e) { console.log("caught While"); }
		try { shapeDoWhile(true, 1, xs); } catch (e) { console.log("caught DoWhile"); }
		try { shapeForOf(true, 1, xs); } catch (e) { console.log("caught ForOf"); }
		try { shapeForC(true, 1, xs); } catch (e) { console.log("caught ForC"); }
		try { shapeMatch(true, 1, xs); } catch (e) { console.log("caught Match"); }
		try { shapeMatchExpr(true, 1, xs); } catch (e) { console.log("caught MatchExpr"); }
		try { shapeBlock(true, 1, xs); } catch (e) { console.log("caught Block"); }
		try { shapeTryFin(true, 1, xs); } catch (e) { console.log("caught TryFin"); }
		try { shapeCatchBody(true, 1, xs); } catch (e) { console.log("caught CatchBody"); }
		try { shapeIfCond(true, 1, xs); } catch (e) { console.log("caught IfCond"); }
		try { shapeWhileCond(true, 1, xs); } catch (e) { console.log("caught WhileCond"); }
		try { shapeForCond(true, 1, xs); } catch (e) { console.log("caught ForCond"); }
		try { shapeTernary(true, 1, xs); } catch (e) { console.log("caught Ternary"); }
		try { shapeShortCirc(true, 1, xs); } catch (e) { console.log("caught ShortCirc"); }
		try { shapeBinInit(true, 1, xs); } catch (e) { console.log("caught BinInit"); }
		try { shapeArgNest(true, 1, xs); } catch (e) { console.log("caught ArgNest"); }
		try { shapeMethod(true, 1, xs); } catch (e) { console.log("caught Method"); }
		try { shapeClosure(true, 1, xs); } catch (e) { console.log("caught Closure"); }
		try { shapeReturn(true, 1, xs); } catch (e) { console.log("caught Return"); }
		try { shapeSwitchDisc(true, 1, xs); } catch (e) { console.log("caught SwitchDisc"); }
		try { shapeSwitchCase(true, 1, xs); } catch (e) { console.log("caught SwitchCase"); }
		try { shapeForInit(true, 1, xs); } catch (e) { console.log("caught ForInit"); }
		try { shapeForUpdate(true, 1, xs); } catch (e) { console.log("caught ForUpdate"); }
		try { shapeDoCond(true, 1, xs); } catch (e) { console.log("caught DoCond"); }
		try { shapeIndex(true, 1, xs); } catch (e) { console.log("caught Index"); }
		try { shapeObjLit(true, 1, xs); } catch (e) { console.log("caught ObjLit"); }
		try { shapeNewArg(true, 1, xs); } catch (e) { console.log("caught NewArg"); }
		try { shapeTemplate(true, 1, xs); } catch (e) { console.log("caught Template"); }
		try { shapeMemberOf(true, 1, xs); } catch (e) { console.log("caught MemberOf"); }
		try { shapeUnary(true, 1, xs); } catch (e) { console.log("caught Unary"); }
		try { shapeNestedLoop(true, 1, xs); } catch (e) { console.log("caught NestedLoop"); }
		try { shapeAfterHeld(true, 1, xs); } catch (e) { console.log("caught AfterHeld"); }
	}
	console.log("GUARD-OK");
}
main();
