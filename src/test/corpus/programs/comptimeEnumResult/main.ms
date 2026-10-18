// @stdout: second first third true high
// note: a @comptime call that returns an enum folds to a value of that enum, as the call's own type says: it fits an enum slot and an enum parameter, and compares with a member, from the defining module and through an import.

import { Flavor, pick } from "./flavor";

enum Local { Low, High }

@comptime function level(n: int32): Local {
	return n > 0 ? Local.High : Local.Low;
}

function flavorName(f: Flavor): string {
	if (f == Flavor.First) return "first";
	return f == Flavor.Second ? "second" : "third";
}

function levelName(l: Local): string {
	return l == Local.High ? "high" : "low";
}

const p: Flavor = pick(1);
const q = pick(0);
const r: Flavor = pick(5);
const h = level(3);
const same = p == Flavor.Second;
console.log(`${flavorName(p)} ${flavorName(q)} ${flavorName(r)} ${same} ${levelName(h)}`);
