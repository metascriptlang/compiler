// nim-guard: ORC collects a cycle that passes through a closure environment
//
// INVARIANT (reference liftdestructors.nim cyclicType: a closure is a cyclic type, and its
//   environment is traced like any cell): the TypeInfo of a lambda environment names its trace
//   hook, so the collector can walk Widget -> closure env -> Widget.
//
// WHAT IT CATCHES: ensureTypeInfoDef wiring destroyFn only (no traceFn / isCyclic) for a
//   compiler-generated $Env type — the collector stops at the env and both cells leak
//   (Widget alloc=N destroy=0).
//
// CONTROL: Plain is a class-only self cycle; its TypeInfo comes from the lifter, so it collects
//   even without the fix. Only Widget red: the env TypeInfo lost its trace hook. Both red: ORC
//   itself broke.
//
// DRC is NOT asserted: DRC does not collect cycles by design.
//
// RED MEANS: a TypeInfo defined in codegen lost its trace hook. Run /trace-nim on Widget.
// GUARD-BALANCE-ORC Widget
// GUARD-BALANCE-ORC Plain

class Widget {
	label: string = "w";
	onClick: (() => string) | null = null;
}
class Plain {
	label: string = "p";
	peer: Plain | null = null;
}

function churn(): int32 {
	let i: int32 = 0;
	while (i < 2000) {
		const w = new Widget();
		w.onClick = (): string => w.label;
		const p = new Plain();
		p.peer = p;
		i = i + 1;
	}
	return i;
}
console.log("done", churn());
