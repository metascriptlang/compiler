// @stdout: field 41 seen 1
// @stdout: direct 43 seen 2
// note: a Sendable reducer sent to an actor calls a function held in a field of its parameter, and another calls a function parameter; the actor passes closures over its own state, so the calls run on the actor's thread. Reduced from the Wings database.

struct Host { get: (key: int32) => int32; }

struct Module {
	call: Sendable<(host: Host, key: int32) => int32>;
	direct: Sendable<(get: (key: int32) => int32, key: int32) => int32>;
}

actor Runner {
	module: Module;
	seen: int32 = 0;
	constructor(module: Module) { this.module = module; }
	run(key: int32): string {
		const host: Host = { get: (k: int32): int32 => { this.seen += 1; return k * 2; } };
		return "field " + String(this.module.call(host, key)) + " seen " + String(this.seen);
	}
	runDirect(key: int32): string {
		const r = this.module.direct((k: int32): int32 => { this.seen += 1; return k * 2; }, key);
		return "direct " + String(r) + " seen " + String(this.seen);
	}
}

const runner = new Runner({
	call: (host: Host, key: int32): int32 => host.get(key) + 1,
	direct: (get: (key: int32) => int32, key: int32): int32 => get(key) + 1,
});
console.log(await runner.run(20));
console.log(await runner.runDirect(21));
