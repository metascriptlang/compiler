// @stdout: written: open shut true
// @stdout: matched: open shut true
// @stdout: nested: 2
enum Q { Open, Shut }
type Gate = { kind: Q.Open; n: int32 } | { kind: Q.Shut; why: string };
type Door = match (kind: Q) {
	Q.Open => { n: int32 },
	Q.Shut => { why: string },
};
class Holder { gate: Gate = { kind: Q.Shut, why: "w" }; }

function name(q: Q): string { return q == Q.Open ? "open" : "shut"; }
function count(q: Q, n: int32): int32 { return q == Q.Shut ? n + 1 : n; }

const gates: Gate[] = [{ kind: Q.Open, n: 1 }, { kind: Q.Shut, why: "w" }];
const g0 = gates[0];
console.log("written: " + name(g0.kind) + " " + name(gates[1].kind) + " " + (gates[0].kind == Q.Open));

const doors: Door[] = [{ kind: Q.Open, n: 1 }, { kind: Q.Shut, why: "w" }];
const d0 = doors[0];
console.log("matched: " + name(d0.kind) + " " + name(doors[1].kind) + " " + (doors[0].kind == Q.Open));

const h = new Holder();
console.log("nested: " + count(h.gate.kind, 1));
