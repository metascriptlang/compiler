// @stdout: add 7
// @stdout: scale 24
// @stdout: push 31
// @serial
// @ledger-slack(Hub) 1
// ledger-slack reason: its actor is never stopped, so it is still live at exit
// note: a Sendable closure passed to an actor method whose body awaits reaches the suspending _impl by value, like any other value-layout argument.

type Snap = Sendable<() => Promise<int64>>;
type Mul = Sendable<(n: int64) => Promise<int64>>;

actor Hub {
	seen: int64 = 0;
	add(snap: Snap): int64 {
		this.seen = await snap();
		return this.seen;
	}
	scale(f: Mul, g: Mul): int64 {
		const a = await f(2);
		const b = await g(3);
		this.seen = a + b;
		return this.seen;
	}
	push(snap: Snap): void {
		this.seen += await snap();
	}
	get(): int64 {
		return this.seen;
	}
}

async function main(): Promise<void> {
	const hub = new Hub();
	const seven: Snap = async (): Promise<int64> => 7;
	console.log(`add ${await hub.add(seven)}`);
	const tenfold: Mul = async (n: int64): Promise<int64> => n * 10;
	const next: Mul = async (n: int64): Promise<int64> => n + 1;
	console.log(`scale ${await hub.scale(tenfold, next)}`);
	hub.push(seven);
	console.log(`push ${await hub.get()}`);
}

await main();
