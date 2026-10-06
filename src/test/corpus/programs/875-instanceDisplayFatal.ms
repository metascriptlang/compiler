// @exit: 1
// @stdout: before 7
// @skip-js: node exits 1 with the same "invalid object conversion" line but wraps it in its own uncaught-error report (sibling of 647/826)
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other class's memory instead of stopping
// @xfail(raiser): the Raiser VM does not check object conversions
// note: the fatal checked `as` over a deep chain (object depth 7, target an ancestor's
// other child) — msObjDownConv → msIsInstance display check must still refuse. Sibling of 647.

class C0 { id: number = 0; }
class C1 extends C0 {}
class C2 extends C1 {}
class C3 extends C2 {}
class C4 extends C3 {}
class C5 extends C4 {}
class C6 extends C5 {}
class Deep extends C6 { l: number = 7; }
class Sib extends C0 { s: number = 1; }

function deepOf(u: unknown): number {
	return (u as Deep).l;
}

function main(): void {
	const deep: unknown = new Deep();
	console.log(`before ${deepOf(deep)}`);
	console.log(`after ${deepOf(new Sib())}`);
}
main();
