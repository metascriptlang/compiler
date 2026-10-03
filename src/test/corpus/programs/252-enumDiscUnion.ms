enum EvKind { Click, Key, Wheel }

interface ClickEv { kind: EvKind.Click; x: int32; }
interface KeyEv { kind: EvKind.Key; code: int32; }
interface WheelEv { kind: EvKind.Wheel; delta: int32; }

type Ev = ClickEv | KeyEv | WheelEv;

function describe(e: Ev): string {
	return JSON.stringify(e);
}

function main(): void {
	const a: Ev = { kind: EvKind.Click, x: 7 };
	const b: Ev = { kind: EvKind.Key, code: 42 };
	const c: Ev = { kind: EvKind.Wheel, delta: -3 };
	console.log(describe(a));
	console.log(describe(b));
	console.log(describe(c));

	const back = JSON.parse<Ev>(describe(b));
	console.log(back.ok ? "decoded" : "failed");

	const bad = JSON.parse<Ev>(`{"kind":"Nope","x":1}`);
	console.log(bad.ok ? "decoded" : "failed");

	const evs: Ev[] = [a, b, c];
	let i = 0;
	while (i < evs.length) {
		console.log(describe(evs[i]));
		i = i + 1;
	}
}
main();
