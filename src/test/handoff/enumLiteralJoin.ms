import { TypeKind } from "../../ast/node";
import { createEnumLiteral, typeDisplayName } from "../../checker/types";
import { joinBranchTypes } from "../../checker/fit";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "./helpers";

test "enumLiteralJoin: a member joined with its own enum is the enum, whichever arm comes first" {
	const ctx = checkSource("enum StmtKind { Block, Return }");
	const sym = lookupSymbol(ctx.table, "StmtKind");
	assert sym != null;
	const kind = sym.symbolType;
	const member = createEnumLiteral(kind, "Block");
	const memberLast = joinBranchTypes([kind, member]);
	const memberFirst = joinBranchTypes([member, kind]);
	assert memberLast.kind == TypeKind.Enum;
	assert memberFirst.kind == TypeKind.Enum;
	assert typeDisplayName(memberLast) == "StmtKind";
	assert typeDisplayName(memberFirst) == "StmtKind";
}

test "enumLiteralJoin: a joined set of members meeting its enum is the enum" {
	const ctx = checkSource("enum StmtKind { Block, Return, Expr }");
	const sym = lookupSymbol(ctx.table, "StmtKind");
	assert sym != null;
	const kind = sym.symbolType;
	const inner = joinBranchTypes([createEnumLiteral(kind, "Expr"), createEnumLiteral(kind, "Block")]);
	assert typeDisplayName(joinBranchTypes([inner, kind])) == "StmtKind";
	assert typeDisplayName(joinBranchTypes([kind, inner])) == "StmtKind";
}

test "enumLiteralJoin: two members of one enum still join as a union of members" {
	const ctx = checkSource("enum StmtKind { Block, Return }");
	const sym = lookupSymbol(ctx.table, "StmtKind");
	assert sym != null;
	const joined = joinBranchTypes([createEnumLiteral(sym.symbolType, "Block"), createEnumLiteral(sym.symbolType, "Return")]);
	assert joined.kind != TypeKind.Enum;
}
