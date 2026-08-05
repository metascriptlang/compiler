// bug083 — `Color.Purple` on an enum without that member passed the checker.
// The enum branch of checkMemberExpr computed `memberExists` but used it only
// to pick the reported type, then rewrote the node to the mangled identifier
// regardless — so the failure surfaced as a C compiler error on
// `Color_Purple` (or a JS ReferenceError), with a mangled name and no source
// location. Struct and class member access already reported it correctly.
//
// The rewrite itself is a deliberate divergence (NIM-REF row 72: the mangled
// name IS the C identifier, so codegen never special-cases enum MemberExpr).
// What was missing is the reference's "not found" arm: tryReadingTypeField
// returns nil for an unknown enum field and sem reports `undeclared field`.

import { compileToC } from "../helpers";

const missing = `
enum Color { Red, Green }

export function pick(): int32 {
	return Color.Purple as int32;
}
`;

const present = `
enum Color { Red, Green }

export function pick(): int32 {
	return Color.Green as int32;
}
`;

const missingInMatch = `
enum Color { Red, Green }

export function name(c: Color): string {
	return match (c) {
		Color.Red => "r",
		Color.Purple => "p",
		_ => "x",
	};
}
`;

test "unknown enum member is rejected by the checker" {
	const c = compileToC(missing);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("Purple") >= 0, "message does not name the member: " + c.error;
	assert c.error.indexOf("Color") >= 0, "message does not name the enum: " + c.error;
}

test "unknown enum member in a match arm is rejected" {
	const c = compileToC(missingInMatch);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("Purple") >= 0, "message does not name the member: " + c.error;
}

test "existing enum member still compiles" {
	const c = compileToC(present);
	assert c.ok, "valid enum member rejected: " + (c.ok ? "" : c.error);
}

// Extern enums mangle to the bare C name, but the declaration is still the only
// member list the checker has. Reference parity: an `importc` enum resolves
// against the members declared in the binding, not the ones the C header
// defines, so an unlisted member is `undeclared field` there too.
const externPresent = `
extern enum Flags { A, B }

export function ok(): int32 { return Flags.A as int32; }
`;

const externMissing = `
extern enum Flags { A, B }

export function bad(): int32 { return Flags.C as int32; }
`;

test "declared extern enum member passes the checker" {
	const c = compileToC(externPresent);
	assert c.ok, "declared extern member rejected: " + (c.ok ? "" : c.error);
}

test "undeclared extern enum member is rejected" {
	const c = compileToC(externMissing);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("Flags") >= 0, "message does not name the enum: " + c.error;
}
