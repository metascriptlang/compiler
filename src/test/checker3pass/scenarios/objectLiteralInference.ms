import { checkOnly } from "../helpers";
import { Node, NodeKind, ObjectLiteralData } from "../../../ast/node";
import { typeDisplayName } from "../../../checker/types";
import { forEachChild } from "../../../ast/visitor";

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

function literalTypes(n: Node, out: string[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.ObjectLiteral) {
		const keys = (n.data as ObjectLiteralData).keys;
		if (keys.length > 0 && (keys[0] == "id" || keys[0] == "x")) out.push(keys[0] + ":" + typeDisplayName(n.nodeType));
	}
	forEachChild(n, (child: Node): void => { literalTypes(child, out); });
}

test "a literal for a struct inferred from a sibling field is typed as that struct, nested fields included" {
	const result = checkOnly(`
interface Def<P> { name: string; show: (p: P) => string; }
interface ToOptions<P> { to: Def<P>; params: P; }
struct Point { x: int32; y: int32 }
struct Placed { id: string; at: Point }
struct Detail { id: string }
function go<P>(to: ToOptions<P>): string { return to.to.show(to.params); }
class O {
	go(href: string): string { return href; }
	go<P>(to: ToOptions<P>): string { return to.to.show(to.params); }
}
const placed: Def<Placed> = { name: "placed", show: (p: Placed): string => p.id };
const detail: Def<Detail> = { name: "detail", show: (p: Detail): string => p.id };
const o = new O();
const d = go({ to: detail, params: { id: "0" } });
const e = o.go<Detail>({ to: detail, params: { id: "0" } });
const a = go({ to: placed, params: { id: "1", at: { x: 1, y: 2 } } });
const b = o.go({ to: placed, params: { id: "2", at: { x: 3, y: 4 } } });
const c = o.go<Placed>({ to: placed, params: { id: "3", at: { x: 5, y: 6 } } });
`);
	assert result.errors.length == 0, "the calls must check: " + result.errors.join("\n");
	const got: string[] = [];
	literalTypes(result.program, got);
	assert got.join(",") == "id:Detail,id:Detail,id:Placed,x:Point,id:Placed,x:Point,id:Placed,x:Point", "got " + got.join(",");
}
