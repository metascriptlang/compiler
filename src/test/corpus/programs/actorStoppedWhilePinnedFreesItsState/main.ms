// @stdout: B stopped while another thread pinned it: true
// @skip-js: binds the C fixture pinnedStop.c, which pins B through the runtime's pid table from another thread
// @skip-raiser: binds the C fixture pinnedStop.c, which has no Raiser host bridge
// note: B lives on the pool worker that ran the spawn. Its owner retires it while another thread
//   holds a pid pin, which defers the state's teardown; the program then reaches its end. The SAN
//   lane's ledger shows whether B and its Payload were destroyed before exit: before exit waited
//   for deferred states, the worker parked with B on its deferred list and both leaked.
@include("./pinnedStop.h")
@compile("./pinnedStop.c")
extern function probeMade(): void;
extern function probeWaitMade(): int32;
extern function probeStopWhilePinned(pid: int64): int32;

class Payload {
	n: int32 = 7;
}

actor B {
	payload: Payload = new Payload();
	take(v: int32): void {
		this.payload.n = v;
	}
}

const made = spawn((): B => {
	const b = new B();
	probeMade();
	return b;
});
let ok = probeWaitMade() == 1;
const b = await made;
ok = ok && probeStopWhilePinned(b.pid) == 1;
console.log(`B stopped while another thread pinned it: ${ok}`);
