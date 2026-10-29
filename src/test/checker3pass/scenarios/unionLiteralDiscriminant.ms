import { checkOnly } from "../helpers";

const DIR = `
enum Kind { Inherit, Home, Path }
struct Dir = match (kind: Kind) {
	Kind.Inherit => {},
	Kind.Home => {},
	Kind.Path => { path: string },
};
struct Wide = match (kind: Kind) {
	Kind.Inherit => { n: number },
	Kind.Home => { n: number, m: number },
	Kind.Path => { path: string },
};
struct Flag = match (ok: boolean) {
	true => { v: number },
	false => { err: string },
};
`;

test "a conditional between two variants with equal payloads is refused at the discriminant" {
	const text = checkOnly(DIR + `
function a(cli: boolean): Dir { return { kind: cli ? Kind.Inherit : Kind.Home }; }
`).errors.join("\n");
	assert text.contains("the discriminant 'kind' can be Kind.Inherit or Kind.Home: a 'Dir' literal builds the one variant"), "equal payloads: " + text;
}

test "a conditional between variants with different payloads names the variant lacking the field" {
	const text = checkOnly(DIR + `
function a(cli: boolean): Wide { return { kind: cli ? Kind.Inherit : Kind.Home, m: 1 }; }
`).errors.join("\n");
	assert text.contains("the discriminant 'kind' can be Kind.Inherit, whose variant Kind.Inherit of 'Wide' has no field 'm'"), "different payloads: " + text;
}

test "a conditional inside a nullish coalesce is refused" {
	const text = checkOnly(DIR + `
function a(d: Dir | null, cli: boolean): Kind {
	const e: Dir = d ?? { kind: cli ? Kind.Inherit : Kind.Home };
	return e.kind;
}
`).errors.join("\n");
	assert text.contains("the discriminant 'kind' can be Kind.Inherit or Kind.Home"), "nested in ??: " + text;
}

test "a discriminant typed as a union of members is refused" {
	const text = checkOnly(DIR + `
function a(k: Kind.Inherit | Kind.Home): Dir { return { kind: k }; }
`).errors.join("\n");
	assert text.contains("the discriminant 'kind' can be Kind.Inherit or Kind.Home"), "union-typed variable: " + text;
}

test "a discriminant typed as the whole enum or boolean is refused" {
	const text = checkOnly(DIR + `
function a(k: Kind): Dir { return { kind: k }; }
function b(ok: boolean): Flag { return { ok: ok, v: 1 }; }
`).errors.join("\n");
	assert text.contains("the discriminant 'kind' can be Kind.Inherit or Kind.Home or Kind.Path"), "whole enum: " + text;
	assert text.contains("the discriminant 'ok' can be false, whose variant false of 'Flag' has no field 'v'"), "boolean discriminant: " + text;
}

test "a discriminant of another enum names no variant" {
	const text = checkOnly(DIR + `
enum Other { Inherit }
function a(): Dir { return { kind: Other.Inherit }; }
`).errors.join("\n");
	assert text.contains("which names no variant of 'Dir'"), "foreign member: " + text;
}

test "a written member, and a conditional of whole literals, are accepted" {
	const errors = checkOnly(DIR + `
function a(cli: boolean): Dir { return cli ? { kind: Kind.Inherit } : { kind: Kind.Home }; }
function b(): Dir { return { kind: Kind.Path, path: "p" }; }
function c(ok: boolean): Flag { return ok ? { ok: true, v: 1 } : { ok: false, err: "e" }; }
`).errors;
	assert errors.length == 0, "one variant per literal: " + errors.join("\n");
}
