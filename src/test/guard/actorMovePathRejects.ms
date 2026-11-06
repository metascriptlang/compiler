// nim-guard: a field, element or call moved into an actor method must be isolated.
//
// INVARIANT (ULTRALOCK V2, N5): `move got.data` hands over part of got's graph, so got must be the
//   sole owner of that graph, as when got itself moves: bound only from a fresh value and never
//   aliased before the move. Any other moved operand must be a fresh value.
//
// WHAT IT CATCHES: the actor-argument check covering only `move <name>`, where a field of a local
//   that shares its buffer with a module const or a second struct crossed to the actor's thread
//   with no error (measured 2026-11-06 on msc ad50eb00424), and `move Buffer.copy(p)` crossing
//   while `const k = Buffer.copy(p); move k` was refused; and a destructured binding reported as
//   "declared outside the enclosing function".
//
// RED MEANS: one of the shapes below compiles again.
//
// GUARD-CHECK-FAIL cannot move 'got.data': it is not the sole owner — the value bound to 'got'
// GUARD-CHECK-FAIL it is stored in an object literal
// GUARD-CHECK-FAIL cannot move this value: it is not the sole owner
// GUARD-CHECK-FAIL the value destructured into 'data'

struct Read { data: Buffer; }

actor Sink {
	frame(data: Buffer): void { console.log(`frame ${data.length}`); }
}

const keep: Buffer = Buffer.alloc(1);

function fieldOfAShared(sink: Readonly<Sink>): void {
	let got: Read = { data: keep };
	sink.frame(move got.data); // GUARD-REFUSED
}

function fieldStoredTwice(sink: Readonly<Sink>): void {
	let got: Read = { data: Buffer.alloc(1) };
	let other: Read = { data: got.data };
	sink.frame(move got.data); // GUARD-REFUSED
	console.log(other.data.length);
}

function callOfAParameter(sink: Readonly<Sink>, secret: Buffer): void {
	sink.frame(move Buffer.copy(secret)); // GUARD-REFUSED
}

function destructuredFromALiveLocal(sink: Readonly<Sink>): void {
	let got: Read = { data: Buffer.alloc(1) };
	const { data } = got;
	sink.frame(move data); // GUARD-REFUSED
	console.log(got.data.length);
}

const s = new Sink();
fieldOfAShared(s);
fieldStoredTwice(s);
callOfAParameter(s, Buffer.alloc(2));
destructuredFromALiveLocal(s);
