// @stdout: true true true true true true true true
// note: a `let` or `var` initialized from an enum member is the enum, so another member can be assigned to it, in code a macro runs as in a plain function. A macro helper is rechecked from a tree whose member nodes already carry their member symbol, and the recheck gave the node the member's literal type where the first check gave the enum. Variants: let, var, a loop assignment, a ternary of members, a destructured let, a for-header let, an enum with explicit values, a class field.

import { Node, NodeKind } from "std/meta";

enum Kind { Block, Return, Expr }
enum Tag { A = 10, B = 20 }
class Stmt { kind: Kind = Kind.Block; tag = Tag.A; }

function viaLet(body: Stmt[]): boolean { let last = Kind.Block; last = Kind.Return; return last == Kind.Return; }
function viaVar(body: Stmt[]): boolean { var last = Kind.Block; last = Kind.Return; return last == Kind.Return; }
function viaLoop(body: Stmt[]): boolean { let last = Kind.Block; for (const s of body) last = s.kind; last = Kind.Return; return last == Kind.Return; }
function viaTernary(body: Stmt[]): boolean { let last = body.length > 5 ? Kind.Return : Kind.Expr; last = Kind.Block; return last == Kind.Block; }
function viaDestructure(body: Stmt[]): boolean { let { kind } = body[0]; kind = Kind.Return; return kind == Kind.Return; }
function viaFor(body: Stmt[]): boolean { let n = 0; for (let k = Kind.Block; k != Kind.Return; k = Kind.Return) n += 1; return n == 1; }
function viaValues(body: Stmt[]): boolean { let t = Tag.A; t = Tag.B; return t == Tag.B; }
function viaField(body: Stmt[]): boolean { const s = new Stmt(); s.tag = Tag.B; s.kind = Kind.Expr; return s.kind == Kind.Expr && s.tag == Tag.B; }

macro mLet(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaLet([new Stmt()]) }; }
macro mVar(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaVar([new Stmt()]) }; }
macro mLoop(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaLoop([new Stmt()]) }; }
macro mTernary(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaTernary([new Stmt()]) }; }
macro mDestructure(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaDestructure([new Stmt()]) }; }
macro mFor(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaFor([new Stmt()]) }; }
macro mValues(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaValues([new Stmt()]) }; }
macro mField(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaField([new Stmt()]) }; }

console.log(`${mLet()} ${mVar()} ${mLoop()} ${mTernary()} ${mDestructure()} ${mFor()} ${mValues()} ${mField()}`);
