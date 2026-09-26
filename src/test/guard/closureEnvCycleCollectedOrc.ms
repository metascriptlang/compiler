// nim-guard: under ORC a cycle that runs through a closure's environment is
// collected.
//
// Nim liftdestructors.nim cyclicType (`tyProc: callConv == ccClosure`) and
// atomicClosureOp (nimDecRefIsLastCyclicDyn / nimIncRefCyclic, attachedTrace ->
// nimTraceRefDyn); ccgtypes.nim genTypeInfoV2 sets traceImpl for every type.
// NIM-REF CG-2 (ensureTypeInfoDef). Proven red on main c36ed0ab, whose env TypeInfo
// had no traceFn and whose msClosureDestroy used plain msDecref: Widget alloc=200
// destroy=0, Btn alloc=1 destroy=0, Tag alloc=200 destroy=0, Kept alloc=1200
// destroy=0 under orc; the msDecref alone leaves Kept alloc=1200 destroy=1189.
//
// RED MEANS an env TypeInfo lost its traceFn or a closure release stopped
// registering the env as a cycle candidate; run /trace-nim on the named type.
//
// GUARD-BALANCE-ORC Widget
// GUARD-BALANCE-ORC Btn
// GUARD-BALANCE-ORC Tag
// GUARD-BALANCE-ORC Kept

class Widget {
	label: string = "w";
	onClick: (() => string) | null = null;
}

class Btn {
	name: string;
	onClick: () => void;
	constructor(n: string) { this.name = n; this.onClick = () => {}; }
}

class Tag {
	hits: int32 = 0;
}

function widgetCycle(): void {
	const w = new Widget();
	w.onClick = (): string => w.label;
}

function reassignedHandler(): string {
	const b = new Btn("b");
	b.onClick = () => { b.name = b.name + "!"; };
	b.onClick();
	return b.name;
}

function selfRecursive(): int32 {
	const tag = new Tag();
	let fib: ((n: int32) => int32) | null = null;
	fib = (n: int32): int32 => {
		tag.hits += 1;
		if (n < 2) return n;
		return fib!(n - 1) + fib!(n - 2);
	};
	return fib!(5);
}

class Kept {
	hits: int32 = 0;
}

function mkSelf(): () => int32 {
	const kept = new Kept();
	let self: (() => int32) | null = null;
	self = (): int32 => {
		kept.hits += 1;
		return self != null ? kept.hits : 0;
	};
	return self!;
}

function keptPastCollect(): int32 {
	let s: int32 = 0;
	for (let round: int32 = 0; round < 4; round += 1) {
		let keep: (() => int32) | null = null;
		for (let i: int32 = 0; i < 300; i += 1) {
			const c = mkSelf();
			s = s + c();
			if (i == 0) keep = c;
		}
		if (keep != null) s = s + keep();
	}
	return s;
}

function main(): void {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 200; i += 1) {
		widgetCycle();
		s = s + selfRecursive();
	}
	console.log(reassignedHandler());
	console.log(s);
	console.log(keptPastCollect());
	console.log("GUARD-OK");
}
main();
