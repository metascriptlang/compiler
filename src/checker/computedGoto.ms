// `@computedGoto;` — a directive statement in the body of a `while (true)` loop. The C backend
// dispatches the loop's switch through a table of label addresses; the checker owns every refusal.

import { Node, NodeKind, Type, TypeKind, SymbolKind, ExprStmtData, MacroInvocationData, BlockStmtData, WhileStmtData, SwitchStmtData, SwitchCaseData, NumberLiteralData } from "../ast/node";
import { CheckerContext, addError } from "./context";
import { enumOrdinalBounds, peelThrough, PEEL_ALL } from "./types";
import { isAlwaysTrue } from "./initTracker";

const MAX_CASES: int32 = 10000;

export function isComputedGotoMark(stmt: Node): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const expr = (stmt.data as ExprStmtData).expr;
	return expr.kind == NodeKind.MacroInvocation && (expr.data as MacroInvocationData).macroName == "computedGoto";
}

export function computedGotoMarks(body: Node): Node[] {
	const marks: Node[] = [];
	if (body.kind != NodeKind.BlockStmt) return marks;
	for (const s of (body.data as BlockStmtData).statements) {
		if (isComputedGotoMark(s)) marks.push(s);
	}
	return marks;
}

export function isRegisteredMark(ctx: CheckerContext, stmt: Node): boolean {
	for (const m of ctx.computedGotoMarks) {
		if (m == stmt) return true;
	}
	return false;
}

export function computedGotoDiscriminant(t: Type | null): Type | null {
	if (t == null) return null;
	const peeled = peelThrough(t, PEEL_ALL) ?? t;
	return peeled.kind == TypeKind.EnumLiteral && peeled.typeReturn != null ? peeled.typeReturn : peeled;
}

// The number of table slots for a discriminant of this type, 0 when it has no table.
export function computedGotoSize(t: Type | null): int32 {
	const d = computedGotoDiscriminant(t);
	if (d == null) return 0;
	if (d.kind == TypeKind.Enum) return d.typeNames.length;
	if (d.kind == TypeKind.Uint8) return 256;
	return 0;
}

function refuse(ctx: CheckerContext, at: Readonly<Node>, message: string): void {
	addError(ctx, message, at.location.line, at.location.column);
}

export function refuseComputedGotoMisuse(ctx: CheckerContext, loop: Node, mark: Node): void {
	const wd = loop.data as WhileStmtData;
	const directive = (mark.data as ExprStmtData).expr;
	if ((directive.data as MacroInvocationData).macroArgs.length > 0) {
		refuse(ctx, directive, "@computedGoto takes no argument");
		return;
	}
	if (!isAlwaysTrue(wd.whileCondition)) {
		refuse(ctx, directive, "@computedGoto needs a 'while (true)' loop");
		return;
	}
	let found = false;
	for (const s of (wd.whileBody.data as BlockStmtData).statements) {
		if (s.kind != NodeKind.SwitchStmt) continue;
		found = true;
		if (!acceptsSwitch(ctx, s)) return;
	}
	if (!found) refuse(ctx, directive, "no case statement found for computed goto");
}

function acceptsSwitch(ctx: CheckerContext, sw: Node): boolean {
	const sd = sw.data as SwitchStmtData;
	for (const c of sd.switchCases) {
		if ((c.data as SwitchCaseData).isDefault) {
			refuse(ctx, sw, "case statement must be exhaustive for computed goto");
			return false;
		}
	}
	const t = computedGotoDiscriminant(sd.switchDisc.nodeType);
	if (t == null) return true;
	if (t.kind == TypeKind.Enum) return acceptsEnum(ctx, sw, sd, t);
	if (t.kind == TypeKind.Uint8) return acceptsUint8(ctx, sw, sd);
	if (t.kind == TypeKind.Int8) {
		refuse(ctx, sw, "case statement has to start at 0 for computed goto");
		return false;
	}
	if (t.kind == TypeKind.Number || t.kind == TypeKind.Int16 || t.kind == TypeKind.Int32 || t.kind == TypeKind.Int64
			|| t.kind == TypeKind.Uint16 || t.kind == TypeKind.Uint32 || t.kind == TypeKind.Uint64) {
		refuse(ctx, sw, "case statement has too many cases for computed goto");
		return false;
	}
	refuse(ctx, sw, "case statement needs an enum or integer value for computed goto");
	return false;
}

// The checker rewrites `Op.A` to an identifier whose symbol is the member.
function enumMemberOf(test: Readonly<Node>): string {
	const sym = test.resolvedSym;
	if (test.kind != NodeKind.Identifier || sym == null || sym.symbolKind != SymbolKind.EnumMember || sym.symbolType == null) return "";
	const lit = sym.symbolType;
	return lit.kind == TypeKind.EnumLiteral && lit.typeNames.length > 0 ? lit.typeNames[0] : "";
}

function acceptsEnum(ctx: CheckerContext, sw: Node, sd: Readonly<SwitchStmtData>, t: Type): boolean {
	const count = t.typeNames.length;
	const bounds = enumOrdinalBounds(t);
	if (bounds[1] - bounds[0] + 1 != count) {
		refuse(ctx, sw, "case statement cannot work on enums with holes for computed goto");
		return false;
	}
	if (count > MAX_CASES) {
		refuse(ctx, sw, "case statement has too many cases for computed goto");
		return false;
	}
	if (bounds[0] != 0) {
		refuse(ctx, sw, "case statement has to start at 0 for computed goto");
		return false;
	}
	const covered: string[] = [];
	for (const c of sd.switchCases) {
		for (const test of (c.data as SwitchCaseData).caseTests) {
			const member = enumMemberOf(test);
			if (member == "") {
				refuse(ctx, test, `computed goto needs each case label to name a member of '${t.typeName}'`);
				return false;
			}
			covered.push(member);
		}
	}
	for (const member of t.typeNames) {
		if (!covered.includes(member)) {
			refuse(ctx, sw, "case statement must be exhaustive for computed goto");
			return false;
		}
	}
	return true;
}

function acceptsUint8(ctx: CheckerContext, sw: Node, sd: Readonly<SwitchStmtData>): boolean {
	const seen: boolean[] = [];
	for (let i = 0; i < 256; i += 1) seen.push(false);
	for (const c of sd.switchCases) {
		for (const test of (c.data as SwitchCaseData).caseTests) {
			if (test.kind != NodeKind.NumberLiteral) {
				refuse(ctx, test, "computed goto needs each case label of an integer to be a literal");
				return false;
			}
			const v = (test.data as NumberLiteralData).intVal as int32;
			if (v >= 0 && v < 256) seen[v] = true;
		}
	}
	for (const s of seen) {
		if (!s) {
			refuse(ctx, sw, "case statement must be exhaustive for computed goto");
			return false;
		}
	}
	return true;
}

export function refuseComputedGotoDecorator(ctx: CheckerContext, decorators: Node[]): void {
	for (const dec of decorators) {
		if (dec.kind == NodeKind.MacroInvocation && (dec.data as MacroInvocationData).macroName == "computedGoto") {
			refuse(ctx, dec, "@computedGoto marks a statement of a while loop body, not a declaration");
		}
	}
}
