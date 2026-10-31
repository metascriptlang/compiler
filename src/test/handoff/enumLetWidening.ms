import { compileToCWithStd } from "../helpers";

const header = `import { Node, NodeKind } from "std/meta";
enum Kind { Block, Return, Expr }
enum Tag { A = 10, B = 20 }
class Stmt { kind: Kind = Kind.Block; tag = Tag.A; }
`;

const forms = [
	"let last = Kind.Block; last = Kind.Return; return last == Kind.Return;",
	"var last = Kind.Block; last = Kind.Return; return last == Kind.Return;",
	"let last = Kind.Block; for (const s of body) last = s.kind; last = Kind.Return; return last == Kind.Return;",
	"let last = body.length > 0 ? Kind.Return : Kind.Expr; last = Kind.Block; return last == Kind.Block;",
	"let { kind } = body[0]; kind = Kind.Return; return kind == Kind.Return;",
	"for (let k = Kind.Block; k != Kind.Return; k = Kind.Return) { } return true;",
	"let t = Tag.A; t = Tag.B; return t == Tag.B;",
	"const s = new Stmt(); s.tag = Tag.B; s.kind = Kind.Expr; return s.kind == Kind.Expr;",
];

test "enum let widening: a let from an enum member takes the enum in a plain function" {
	for (const form of forms) {
		const result = compileToCWithStd(header + "function f(body: Stmt[]): boolean { " + form + " } console.log(f([new Stmt()]));");
		assert result.ok, form + " " + result.error;
	}
}

test "enum let widening: a let from an enum member takes the enum in code a macro runs" {
	for (const form of forms) {
		const result = compileToCWithStd(header + "function f(body: Stmt[]): boolean { " + form
			+ " } macro m(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: f([new Stmt()]) }; } console.log(m());");
		assert result.ok, form + " " + result.error;
	}
}

test "enum let widening: a const from an enum member still refuses another member" {
	const result = compileToCWithStd(header + "const c = Kind.Block; const d: Kind.Return = c;");
	assert !result.ok;
	assert result.error.contains("not assignable"), result.error;
}
