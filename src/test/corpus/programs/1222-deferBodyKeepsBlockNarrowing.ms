// @stdout: work
// @stdout: close 3
// @stdout: guard
// @stdout: close 3
// @stdout: expr
// @stdout: close 4
// @stdout: let
// @stdout: close 5
// A defer body runs at scope exit but is checked like a closure made at the defer: a binding it cannot see reassigned keeps the narrowing of its block.

function close(n: int32): void {
	console.log(`close ${n}`);
}

function open(n: int32): int32 | null {
	return n > 0 ? n : null;
}

function inBlock(): void {
	const h = open(3);
	if (h != null) {
		defer {
			close(h);
		}
		console.log("work");
	}
}

function afterGuard(): void {
	const h = open(3);
	if (h == null) return;
	defer {
		close(h);
	}
	console.log("guard");
}

function asExpression(): void {
	const h = open(4);
	if (h != null) {
		defer close(h);
		console.log("expr");
	}
}

function neverReassigned(): void {
	let h = open(1);
	h = open(5);
	if (h != null) {
		defer {
			close(h);
		}
		console.log("let");
	}
}

inBlock();
afterGuard();
asExpression();
neverReassigned();
