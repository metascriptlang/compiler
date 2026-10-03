// @stdout: total=4 a6 false
// @xfail(raiser): the Raiser VM cannot evaluate class inheritance (super) or instanceof at comptime
// note: msIsInstance is a display check (arc-style): depth + ancestors' msTypeInfo addresses,
// filled where .base is assigned. This pin covers the matrix at depth 0 and depth ≥ 5 —
// exact hit, ancestor hit, miss, null — plus an overridden method dispatched over the deep
// chain through a base-typed value. Siblings: 732 (dispatchers), 646/647/687/688
// (down-conversions incl. generic), 876 (base in another module), hcr instanceofReload.

class A0 { tag: number = 0;  ident(): string { return "a0"; } }
class A1 extends A0 {}
class A2 extends A1 {}
class A3 extends A2 {}
class A4 extends A3 {}
class A5 extends A4 {}
class A6 extends A5 { ident(): string { return "a6"; } }
class S1 extends A0 { ident(): string { return "s1"; } }

function main(): void {
	const leaf: unknown = new A6();
	const root: unknown = new A0();
	const sib: unknown = new S1();
	const empty: unknown | null = null;

	let total = 0;
	if (root instanceof A0) total += 1;              // exact hit, depth 0
	if (leaf instanceof A6) total += 1;              // exact hit, depth 6
	if (leaf instanceof A0) total += 1;              // ancestor hit, depth 6 -> 0
	if (leaf instanceof A3) total += 1;              // ancestor hit, depth 6 -> 3
	if (leaf instanceof S1) total += 1;              // miss, deep object, sibling branch
	if (sib instanceof A6) total += 1;               // miss, depth 1 -> sibling branch at depth 6
	if (root instanceof A6) total += 1;              // miss, depth 0 against depth 6

	const base: A0 = new A6();
	const parts: string[] = ["total=" + total.toString(), base.ident()];
	if (empty instanceof A6) parts.push("wrong");
	parts.push((empty instanceof A6).toString());
	console.log(parts.join(" "));
}
main();
