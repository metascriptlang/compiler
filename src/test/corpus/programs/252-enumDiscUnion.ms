// @xfail(js): the JS backend emits `K_Member` for an enum member read but never
// emits the `var K_Member = <n>;` declaration unless something else pulls the
// enum in (e.g. reverse-index or Enum_toString, as 230-enumToString does).
// Pre-existing and independent of this program's subject: `enum K { A, B }` +
// `const v = K.A` alone reproduces it on shipped v0.2.34.
// note: TS-style union discriminated by ENUM members — the shape the boolean
// auto-stamp already covered and the enum one did not, so the union was not a
// DU at all and its values could not even be constructed (guard bug091).
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
