// guard: a literal stored in a union with a user hook runs the hook once at scope end, as the same
//   value from a call does
//
// INVARIANT (reference varpartitions.nim:483-488 destMightOwn: an object constructor of a type with
//   a destructor owns, whatever its fields are; a literal is harmless only as a field :446-448):
//   a literal wrapped into a tag-carried union builds a union value that its local owns and destroys.
//
// WHAT IT CATCHES: the literal arm read through the wrap, so the local becomes a cursor and its hook
//   never runs (count 0) while the same value from a call runs it.
//
// AXES: number literal vs string literal vs number local vs new object; literal vs call returning
//   a literal.
//
// RED MEANS: cursor inference treats a union-building conversion as transparent. Run /trace-ref on
//   cursors.ms destMightOwn.
// GUARD-BALANCE Twig

class Twig { s: string = "t"; }
type NP = number | Twig;
type SP = string | Twig;

let npCloses: int32 = 0;
let spCloses: int32 = 0;

function onDestroy(this p: NP): void { npCloses += 1; }
function onDestroy(this p: SP): void { spCloses += 1; }

function eight(): NP { return 8; }
function word(): SP { return "w"; }

function numberLiteral(): void { const k: NP = 8; }
function numberCall(): void { const k: NP = eight(); }
function numberLocal(): void { const n = 3; const k: NP = n; }
function twigNew(): void { const k: NP = new Twig(); }
function stringLiteral(): void { const k: SP = "lit"; }
function stringCall(): void { const k: SP = word(); }

function expect(np: int32, sp: int32, what: string): void {
	if (npCloses != np || spCloses != sp) {
		throw new Error(`${what}: np=${npCloses} sp=${spCloses}, want ${np} ${sp}`);
	}
	npCloses = 0;
	spCloses = 0;
}

function churn(): void {
	numberLiteral();
	expect(1, 0, "number literal");
	numberCall();
	expect(1, 0, "call returning a number literal");
	numberLocal();
	expect(1, 0, "number local");
	twigNew();
	expect(1, 0, "new object");
	stringLiteral();
	expect(0, 1, "string literal");
	stringCall();
	expect(0, 1, "call returning a string literal");
}

for (let i: int32 = 0; i < 20; i += 1) churn();
console.log("GUARD-OK");
