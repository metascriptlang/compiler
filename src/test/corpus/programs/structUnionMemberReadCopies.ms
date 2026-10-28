// @stdout: 5|5 9|5|5|5 null|6#5|5 9|5|5|5 null|6
// note: `p as Left` out of a struct union reads the member in place, so a local it initializes or
// is assigned to holds its own copy, and the array element the union came from is released once.
struct Left { a: int32 }
struct Right { b: int32 }
type Pair = Left | Right;

function pairLeft(): Pair { const l: Left = { a: 5 }; return l; }
function pairRight(): Pair { const r: Right = { b: 6 }; return r; }

function initOf(p: Pair): int32 { const l = p as Left; return l.a; }

function assignOf(p: Pair): string {
	let l: Left = { a: 9 };
	const before = l.a;
	l = p as Left;
	return `${l.a} ${before}`;
}

function show(l: Left): string { return `${l.a}`; }

function returnOf(p: Pair): Left { return p as Left; }

function maybeOf(p: Pair | null): string {
	if (p == null) return "null";
	const l = p as Left;
	return `${l.a}`;
}

function run(): string {
	const list: Pair[] = [pairLeft(), pairRight()];
	const parts: string[] = [];
	parts.push(`${initOf(list[0])}`);
	parts.push(assignOf(list[0]));
	parts.push(show(list[0] as Left));
	parts.push(`${returnOf(list[0]).a}`);
	parts.push(maybeOf(list[0]) + " " + maybeOf(null));
	parts.push(`${(list[1] as Right).b}`);
	return parts.join("|");
}

console.log(run() + "#" + run());
