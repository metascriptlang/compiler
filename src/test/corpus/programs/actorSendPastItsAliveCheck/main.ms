// @stdout: a send that saw B alive and pushed after B stopped: true
// @skip-js: binds the C fixture latePush.c, which pushes into B's mailbox from another thread through the runtime
// @skip-raiser: binds the C fixture latePush.c, which has no Raiser host bridge
// note: another thread pins B, sees it alive, and pushes only after B's owner has stopped and torn it
//   down, as a send preempted between its alive check and its push does. Before the mailbox lived
//   as long as the shell, the push stored through the destroyed queue's NULL head and the program
//   crashed; the SAN lane's ledger shows the late message is dropped and freed with the shell.
@include("./latePush.h")
@compile("./latePush.c")
extern function probeMade(): void;
extern function probeWaitMade(): int32;
extern function probeSendAfterStop(pid: int64): int32;

actor B {
	n: int32 = 0;
	take(v: int32): void {
		this.n = v;
	}
}

const made = spawn((): B => {
	const b = new B();
	probeMade();
	return b;
});
let ok = probeWaitMade() == 1;
const b = await made;
ok = ok && probeSendAfterStop(b.pid) == 1;
console.log(`a send that saw B alive and pushed after B stopped: ${ok}`);
