import { checkOnly } from "../helpers";

const SRC_ROUTES = `
interface Def<P> { name: string; parse: (m: string) => P; }
interface ToOptions<P> { to: Def<P>; params: P; }
interface FromOnly<P> { to: Def<P>; }
interface Detail { id: string }
function viaInline<P>(o: { to: Def<P>; params: P }): P { return o.params; }
function viaInterface<P>(o: ToOptions<P>): P { return o.params; }
function viaInterfaceOne<P>(o: FromOnly<P>): string { return o.to.name; }
class Router { navigate<P>(o: ToOptions<P>): string { return o.to.name; } }
const detail: Def<Detail> = { name: "detail", parse: (m: string): Detail => ({ id: m }) };
const r = new Router();
`;

test "a type parameter is inferred from an object literal field against a generic interface" {
	const errors = checkOnly(SRC_ROUTES + `
const a = viaInterfaceOne({ to: detail });
const b = viaInterface({ to: detail, params: { id: "7" } });
const c = r.navigate({ to: detail, params: { id: "7" } });
`).errors;
	assert errors.length == 0, "the interface calls must check: " + errors.join("\n");
}

test "the named candidate wins over the literal's own type, which it then retypes" {
	const errors = checkOnly(SRC_ROUTES + `
const a: Detail = viaInline({ to: detail, params: { id: "7" } });
const b: Detail = viaInterface({ params: { id: "7" }, to: detail });
`).errors;
	assert errors.length == 0, "P must be Detail: " + errors.join("\n");
}

test "a literal that does not fit the named candidate is still refused" {
	const text = checkOnly(SRC_ROUTES + `
const a = viaInterface({ to: detail, params: { id: 7 } });
const b = viaInline({ to: detail, params: { nope: "7" } });
const c = r.navigate({ to: detail, params: { id: "7", extra: 1 } });
`).errors.join("\n");
	assert text.contains("got { id: int32; }, expected Detail"), "a wrong field type must be refused: " + text;
	assert text.contains("got { nope: string; }, expected Detail"), "a wrong field name must be refused: " + text;
	assert text.contains("got { id: string; extra: int32; }, expected Detail"), "an excess field must be refused: " + text;
}
