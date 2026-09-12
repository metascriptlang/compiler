// A field carrying the actor-isolation intrinsic keeps its initializer: the
// intrinsic wrapper is consumed into the actor symbol when the body is
// collected, so constructor lowering sees a plain field. A red guard means a
// decorator wrapper leaked past the checker and the initializer was dropped.

actor Srv {
	@nonisolated
	readonly name: string = "srv";
	plain: string = "plain";
	inside(): string { return this.name + "|" + this.plain; }
}

async function main(): Promise<int32> {
	const s = new Srv();
	const inside = await s.inside();
	const outside = s.name;
	if (outside != "srv" || inside != "srv|plain") {
		console.log("FAIL outside=" + outside + " inside=" + inside);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const rc = await main();
if (rc != 0) process.exit(rc);
