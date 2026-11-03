// @stdout: ctor 7
// @stdout: arg 7
// @stdout: kept 7
// @stdout: struct 7
// @stdout: array 14
// @stdout: optional 7
// @stdout: nested 7
// note: an actor whose private state holds a plain function crosses to another actor as its pid, as a constructor argument, a method argument, a send, a moved struct field, a moved array, an optional and two actors deep; its function never leaves its own thread.

class Core {
	call: () => int32;
	constructor(call: () => int32) { this.call = call; }
}

actor Inner {
	core: Core;
	constructor() { this.core = new Core((): int32 => 7); }
	value(): int32 { return this.core.call(); }
}

struct Handle { actor: Inner; }

actor Holder {
	inner: Inner;
	constructor(inner: Inner) { this.inner = inner; }
	read(): int32 { return await this.inner.value(); }
}

actor Mid {
	inner: Inner;
	constructor(inner: Inner) { this.inner = inner; }
	value(): int32 { return await this.inner.value(); }
}

actor Top {
	mid: Mid;
	constructor(mid: Mid) { this.mid = mid; }
	read(): int32 { return await this.mid.value(); }
}

actor Reader {
	kept: Inner | null = null;
	handle: Handle | null = null;
	read(inner: Inner): int32 { return await inner.value(); }
	keep(inner: Inner): void { this.kept = inner; }
	readKept(): int32 { const i = this.kept; if (i == null) return 0; return await i.value(); }
	hold(handle: Handle): void { this.handle = handle; }
	readHeld(): int32 { const h = this.handle; if (h == null) return 0; return await h.actor.value(); }
	sum(xs: Inner[]): int32 { let s: int32 = 0; for (const x of xs) s += await x.value(); return s; }
	maybe(i: Inner | null): int32 { if (i == null) return 0; return await i.value(); }
}

async function main(): Promise<void> {
	const holder = new Holder(new Inner());
	console.log(`ctor ${await holder.read()}`);
	const inner = new Inner();
	const reader = new Reader();
	console.log(`arg ${await reader.read(inner)}`);
	reader.keep(inner);
	console.log(`kept ${await reader.readKept()}`);
	let handle: Handle = { actor: new Inner() };
	reader.hold(move handle);
	console.log(`struct ${await reader.readHeld()}`);
	let xs: Inner[] = [new Inner(), new Inner()];
	console.log(`array ${await reader.sum(move xs)}`);
	const maybe: Inner | null = new Inner();
	console.log(`optional ${await reader.maybe(maybe)}`);
	const top = new Top(new Mid(new Inner()));
	console.log(`nested ${await top.read()}`);
}

await main();
