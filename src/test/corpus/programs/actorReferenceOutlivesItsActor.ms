// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: pid kept true | call noproc | other actor sends 2 | stale equals fresh false | fresh pid differs true
import { stop, ExitReason } from "std/actor";

actor Cell {
	buf: string = "gggg";
	ping(): int32 { return this.buf.length; }
	poke(): void { this.buf = this.buf + "g"; }
}

actor Holder {
	held: Cell | null = null;
	keep(c: Cell): int32 { this.held = c; return 1; }
	use(): int32 {
		const h = this.held;
		if (h == null) return 0;
		h.poke();
		return 2;
	}
}

const c = new Cell();
const holder = new Holder();
const pid = c.pid;
await c.ping();
await holder.keep(c);
stop(c.pid, ExitReason.Normal);
await holder.use();

const keptPid = c.pid == pid;
c.poke();
let call = "resolved";
try {
	await c.ping();
} catch (e) {
	call = "noproc";
}
const fromOther = await holder.use();
const fresh = new Cell();
await fresh.ping();
console.log(`pid kept ${keptPid} | call ${call} | other actor sends ${fromOther} | stale equals fresh ${c == fresh} | fresh pid differs ${fresh.pid != pid}`);
stop(fresh.pid, ExitReason.Normal);
stop(holder.pid, ExitReason.Normal);
