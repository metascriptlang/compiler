import { Node, NodeKind, bindSym } from "std/meta";
import { invokeCpi } from "./cpi";

export macro invokeSigned(program: Node, accounts: Node, data: Node, signers: Node): Node {
	if (accounts.kind !== NodeKind.ArrayLiteral) {
		error("accounts must be written as a list at the call: " +
			"[InstructionAccount.writable(vault), InstructionAccount.readonlySigner(owner)]", accounts);
	}
	if (accounts.elements.length > 16) {
		error("a CPI lists at most 16 accounts here, and the list has " +
			(accounts.elements.length as int32) + "; a longer list is invokeList over a run-time list", accounts);
	}
	const blanks: Node[] = [];
	let position = 0;
	while (position < accounts.elements.length) {
		const element = accounts.elements[position];
		const zeros: Node[] = [];
		let field = 0;
		while (field < 9) {
			zeros.push({
				kind: NodeKind.NumberLiteral,
				line: element.line,
				column: element.column,
				value: 0,
				isFloat: false,
				intVal: 0,
				outOfRangeText: "",
				isBitPattern: false,
			});
			field = field + 1;
		}
		blanks.push({
			kind: NodeKind.ObjectLiteral,
			line: element.line,
			column: element.column,
			properties: zeros,
			keys: [
				"key", "lamports", "dataLength", "data", "owner", "rentEpoch", "signer", "writable",
				"executable",
			],
			keyLocations: [],
		});
		position = position + 1;
	}
	return {
		kind: NodeKind.CallExpr,
		line: program.line,
		column: program.column,
		callee: bindSym("invokeCpi"),
		arguments: [
			program,
			accounts,
			{ kind: NodeKind.ArrayLiteral, line: accounts.line, column: accounts.column, elements: blanks },
			data,
			signers,
		],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro invoke(program: Node, accounts: Node, data: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: program.line,
		column: program.column,
		callee: bindSym("invokeSigned"),
		arguments: [
			program,
			accounts,
			data,
			{ kind: NodeKind.ArrayLiteral, line: data.line, column: data.column, elements: [] },
		],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}
