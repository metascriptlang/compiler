import { Node, NodeKind, bindSym } from "std/meta";
import { invokeCpi } from "./core";

export macro invokeSigned(
	program: Node,
	accounts: Node,
	data: Node,
	length: Node,
	signers: Node,
): Node {
	if (accounts.kind !== NodeKind.ArrayLiteral) {
		error("accounts must be written as a list at the call: " +
			"[InstructionAccount.writable(vault), InstructionAccount.readonlySigner(owner)]", accounts);
	}
	if (accounts.elements.length > 64) {
		error("a CPI lists at most 64 accounts, the runtime's limit on the account infos it takes, " +
			"and the list has " + (accounts.elements.length as int32), accounts);
	}
	return {
		kind: NodeKind.CallExpr,
		line: program.line,
		column: program.column,
		callee: bindSym("invokeCpi"),
		arguments: [
			program,
			accounts,
			data,
			length,
			signers,
		],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro invoke(program: Node, accounts: Node, data: Node, length: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: program.line,
		column: program.column,
		callee: bindSym("invokeSigned"),
		arguments: [
			program,
			accounts,
			data,
			length,
			{ kind: NodeKind.ArrayLiteral, line: data.line, column: data.column, elements: [] },
		],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}
