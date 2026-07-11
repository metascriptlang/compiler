// bug044 — primitive unions (float32 | string | null): two latent Maybe bugs
//          + C-layout regression pins for the Maybe<Union> lowering
//
// Symptom:    (a) `let s: string | null = "a"; s = null;` — the null
//             assignment was silently DROPPED (s stayed present). Latent
//             since Maybe landed; exposed by FlexStyle dim fields going
//             `float32 | string | null`. (b) The generated Copy hook for
//             Maybe<string> forwarded only `.present`, never `.value` —
//             copies aliased the payload without incref (double-free under
//             churn).
//
// Root cause: (a) operatorLower's assignment gate only rewrote `= null`
//             when the RHS was already Maybe-shaped storage — the raw
//             NullLiteral arm fell through and the statement vanished.
//             (b) destructorLifting's Maybe copy path skipped the value
//             member.
//
// Fix:        transform/lowering/operatorLower.ms (null-assign gate),
//             transform/lowering/destructorLifting.ms (Maybe copy carries
//             .value; primitive-union hooks are _tag-guarded because union
//             slots hold garbage bits for inactive members).
//
// Note: hook bodies (Destroy/Copy) are emitted once per type per compile
//       process (first-write-wins type cache), so the two hook-body tests
//       MUST run before the call-site tests that reuse their union types.
//       Union member order (which of v0/v1 carries msString) is also
//       cache-state-dependent — assertions stay order-agnostic.

import { compileToC } from "../helpers";

test "bug044: Maybe<string> copy carries .value" {
	const result = compileToC(`
function main(): void {
	let a: string | null = "x";
	const b = a;
	if (b !== null && a !== null) console.log(a);
}
main();
`);
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf("msStringCopy(&((*dest).value), (*src).value)") >= 0;
	}
}

test "bug044: union destroy and copy are _tag-guarded" {
	const result = compileToC(`
function main(): void {
	let d: float32 | string | null = "50%";
	let e: float32 | string | null = d;
	e = 3.0;
	if (e !== null && d !== null) console.log("both");
}
main();
`);
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf("value._tag == ") >= 0;
		assert result.value.indexOf("msStringDecref") >= 0;
		assert result.value.indexOf("msStringCopy(&") >= 0;
	}
}

test "bug044: null assignment on Maybe local is emitted, not dropped" {
	const result = compileToC(`
function main(): void {
	let s: string | null = "some";
	s = null;
	if (s === null) console.log("none");
}
main();
`);
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf("){0}") >= 0;
		assert result.value.indexOf("Sink(") >= 0;
	}
}

test "bug044: union literals construct tagged payloads" {
	const result = compileToC(`
function main(): void {
	let d: float32 | string | null = 12.5;
	d = "50%";
	if (d !== null) console.log("set");
}
main();
`);
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf("._tag = 0, .v0 = ") >= 0;
		assert result.value.indexOf("._tag = 1, .v1 = ") >= 0;
	}
}

test "bug044: typeof lowers to present-gate + _tag dispatch" {
	const result = compileToC(`
function main(): void {
	let d: float32 | string | null = "50%";
	console.log(typeof d);
}
main();
`);
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf(".present ? ") >= 0;
		assert result.value.indexOf("._tag == 0 ? ") >= 0;
	}
}
