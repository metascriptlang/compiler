// @xfail(raiser): the Raiser VM has no actors and runs no user lifecycle hooks
// @skip-js: onDestroy runs where the DRC runs; JS has no destructors
// @stdout: thrown caught=100 freed=100
// @stdout: noproc caught=100
// @serial
// note: `try await x catch v` owns the exception it catches and destroys it when the fallback is
// taken, the way a written `catch (e)` does (old compiler: freed=0, and the SAN ledger counted one
// Error leaked per caught await, both a thrown one and the noproc Error of a CALL to a stopped actor).
import { stop, ExitReason } from "std/actor";

let freed = 0;
class Boom extends Error {}
function onDestroy(this b: Boom): void { freed += 1; }

async function boom(i: int32): Promise<int32> {
	if (i >= 0) throw new Boom(`boom ${i}`);
	return i;
}

actor Sink {
	weigh(): int32 { return 1; }
}

async function thrown(): Promise<int32> {
	let caught = 0;
	for (let i = 0; i < 100; i += 1) {
		const k = try await boom(i) catch -1;
		if (k < 0) caught += 1;
	}
	return caught;
}

async function main(): Promise<void> {
	const caught = await thrown();
	console.log(`thrown caught=${caught} freed=${freed}`);

	let noproc = 0;
	for (let i = 0; i < 100; i += 1) {
		const s = new Sink();
		stop(s.pid, ExitReason.Normal);
		const k = try await s.weigh() catch -1;
		if (k < 0) noproc += 1;
	}
	console.log(`noproc caught=${noproc}`);
}

await main();
