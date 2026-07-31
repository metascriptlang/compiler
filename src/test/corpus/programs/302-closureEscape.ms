// @ledger-slack(msRefArrayRefCell): 1
// Parity program — envs that outlive their creators: returned, stored in
// fields and arrays, invoked long after the frame is gone. DRC must keep the
// captured payloads alive exactly as long as the closure.

type Greeter = () => string;

interface Button {
	label: string;
	onClick: Greeter;
}

function makeGreeter(who: string): Greeter {
	const message = "hi " + who;
	return (): string => message;
}

function wire(label: string, g: Greeter): Button {
	return { label, onClick: g };
}

function main(): void {
	const g = makeGreeter("ada");
	console.log("escaped=" + g());
	console.log("escapedAgain=" + g());

	const buttons: Button[] = [];
	buttons.push(wire("ok", makeGreeter("ok-handler")));
	buttons.push(wire("cancel", makeGreeter("cancel-handler")));
	for (const b of buttons) {
		console.log(b.label + "=>" + b.onClick());
	}

	const items: string[] = [];
	const record = (s: string): void => { items.push(s); };
	record("x");
	record("y");
	console.log("items=" + items.length.toString() + ":" + items[0] + items[1]);

	const base = makeGreeter("core");
	const wrapped = (): string => "[" + base() + "]";
	console.log("wrapped=" + wrapped());
}
main();
