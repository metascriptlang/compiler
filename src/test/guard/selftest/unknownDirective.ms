// SELFTEST-RED unknown directive GUARD-BALANCE-ORC at line 4
// A directive the runner does not parse must be red, or the guard asserts less than it says.
//
// GUARD-BALANCE-ORC Node

class Node {
	next: Node | null = null;
}

const n = new Node();
console.log(n.next == null ? "GUARD-OK" : "GUARD-FAIL");
