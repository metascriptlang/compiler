// @ledger-slack(VArrayRefCell): 1
// note: named-pod-union-array. An array of a named union with no managed member (`type V = boolean | float64`) looped its element hooks and called V_Destroy/V_Copy, which the lifter never generates for a trivial union: the C compile failed with an undeclared function. Fix (3571dccd): a type without hooks is recorded trivial and its containers blit it. Module-level, local, class-field and copied arrays; the module-level cell survives exit (ledger slack).

type V = boolean | float64;

const vs: V[] = [2.5, true];

class Box {
	items: V[] = [];
}

function run(): void {
	const local: V[] = [1.5, false, 3.25];
	const b = new Box();
	b.items.push(true);
	b.items.push(0.5);
	const copy = local.slice(0, local.length);
	copy.push(true);
	console.log(vs.length.toString() + " " + local.length.toString() + " " + b.items.length.toString() + " " + copy.length.toString());
}
run();
