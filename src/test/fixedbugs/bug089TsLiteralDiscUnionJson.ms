// bug089 — a TS-style union of string-literal-disc variants could not be
// JSON-encoded or decoded
//
// Symptom:    `JSON.parse<Shape>` on `type Shape = Circle | Square` (variants
//             discriminated by `kind: "circle"` / `kind: "square"`) reached
//             codegen and died in the emitted C: "cannot take the address of
//             an rvalue of type 'void *'".
// Root cause: same as bug087's second half — `_jsonParseTyped` took a
//             `witness: T | null` param fed a literal `null`, and a by-value
//             union argument has no address to take. The witness carried a
//             type, never a value, so it moved into the body as
//             `null as T | null`.
//
// The sibling instantiation-key collision this file was split away from is
// fixed separately — see bug090.

interface Circle { kind: "circle"; r: float64; }
interface Square { kind: "square"; side: float64; }
type Shape = Circle | Square;

test "JSON.stringify encodes a TS-style literal-disc union value" {
	const s: Shape = { kind: "circle", r: 2.0 };
	assert JSON.stringify(s).includes("circle");
}

test "JSON.parse decodes a TS-style literal-disc union" {
	const r = JSON.parse<Shape>(`{"kind":"square","side":3.0}`);
	assert r.ok;
}

test "JSON.parse rejects an unknown literal discriminator" {
	const r = JSON.parse<Shape>(`{"kind":"triangle","a":1.0}`);
	assert !r.ok;
}
