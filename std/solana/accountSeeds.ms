import { Node, NodeKind, bindSym, getType } from "std/meta";
import { bytesAddress, seedBytes, seedKey, seedText } from "./seed";

export const SEED_LIST_REQUIRED = "seeds must be written as a list at the call: [\"pet\", mint, [bump]]";

const KEY_REQUIRED = "a key is an account or a Pubkey";

function namesAnAccount(name: string, inner: string): boolean {
	return name == "Account" || (name == "Distinct" && inner == "Account") ||
		name == "Signer" || name == "WritableSigner" || name == "Writable" || name == "WritablePda" || name == "SystemAccount" ||
		name == "Program" || name == "Owned" || name == "Mutable" ||
		name == "External" || name == "ExternalMutable" || name == "Delegated";
}

export macro keyAddressOf(operand: Node): Node {
	const line = operand.line;
	const column = operand.column;
	const written = getType(operand);
	let name = "";
	let inner = "";
	if (written != null) {
		if (written.kind === NodeKind.Identifier) { name = written.name; }
		if (written.kind === NodeKind.TypeObject) { name = written.typExprTypeName; }
		if (written.kind === NodeKind.TypeArray) { name = "an array"; }
		if (written.kind === NodeKind.TypeGeneric) {
			name = written.typExprBase.name;
			const first = written.typExprArgs[0];
			if (first.kind === NodeKind.TypeObject) { inner = first.typExprTypeName; }
		}
	}
	if (name == "Pubkey") {
		return {
			kind: NodeKind.CallExpr,
			line: line,
			column: column,
			callee: bindSym("bytesAddress"),
			arguments: [{
				kind: NodeKind.MemberExpr,
				line: line,
				column: column,
				object: operand,
				property: "bytes",
				isOptional: false,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
	}
	if (namesAnAccount(name, inner)) {
		return {
			kind: NodeKind.CallExpr,
			line: line,
			column: column,
			callee: {
				kind: NodeKind.MemberExpr,
				line: line,
				column: column,
				object: operand,
				property: "keyAddress",
				isOptional: false,
			},
			arguments: [],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
	}
	error(KEY_REQUIRED + ", and this has " + (name == "" ? "no known type" : "type " + name +
		(inner == "" ? "" : "<" + inner + ">")), operand);
}

export macro accountAddressOf(operand: Node): Node {
	const written = getType(operand);
	const isPubkey = written != null &&
		((written.kind === NodeKind.Identifier && written.name == "Pubkey") ||
		(written.kind === NodeKind.TypeObject && written.typExprTypeName == "Pubkey"));
	if (isPubkey) {
		error("a mint here must be an account: its owner field names the token program, which a Pubkey does not carry", operand);
	}
	return {
		kind: NodeKind.CallExpr,
		line: operand.line,
		column: operand.column,
		callee: bindSym("keyAddressOf"),
		arguments: [operand],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro seedTable(list: Node): Node {
	if (list.kind !== NodeKind.ArrayLiteral) {
		error(SEED_LIST_REQUIRED, list);
	}
	const slices: Node[] = [];
	let position = 0;
	while (position < list.elements.length) {
		const element = list.elements[position];
		const line = element.line;
		const column = element.column;
		const written = getType(element);
		let builder: Node | null = null;
		let argument: Node = element;
		let description = "no known type";
		if (element.kind === NodeKind.ArrayLiteral) {
			builder = bindSym("seedBytes");
			argument = {
				kind: NodeKind.TypeAssertion,
				line: line,
				column: column,
				asExpr: element,
				asType: "uint8[" + (element.elements.length as int32) + "]",
			};
		}
		if (builder == null && written != null) {
			let name = "";
			let inner = "";
			if (written.kind === NodeKind.Identifier) { name = written.name; }
			if (written.kind === NodeKind.TypeObject) { name = written.typExprTypeName; }
			if (written.kind === NodeKind.TypeArray) { name = "an array"; }
			if (written.kind === NodeKind.TypeGeneric) {
				name = written.typExprBase.name;
				const first = written.typExprArgs[0];
				if (first.kind === NodeKind.TypeObject) { inner = first.typExprTypeName; }
				if (first.kind === NodeKind.TypeArray) { inner = "an array"; }
			}
			description = "type " + name + (inner == "" ? "" : "<" + inner + ">");
			if (name == "string") { builder = bindSym("seedText"); }
			if (name == "an array" || (name == "Ref" && inner == "an array")) {
				builder = bindSym("seedBytes");
			}
			if (name == "Pubkey") {
				builder = bindSym("seedBytes");
				argument = {
					kind: NodeKind.MemberExpr,
					line: line,
					column: column,
					object: element,
					property: "bytes",
					isOptional: false,
				};
			}
			if (namesAnAccount(name, inner)) {
				builder = bindSym("seedKey");
				argument = {
					kind: NodeKind.CallExpr,
					line: line,
					column: column,
					callee: {
						kind: NodeKind.MemberExpr,
						line: line,
						column: column,
						object: element,
						property: "keyAddress",
						isOptional: false,
					},
					arguments: [],
					isDirectCall: false,
					resolvedOverloadIdx: -1,
				};
			}
		}
		if (builder == null) {
			error("seed " + ((position + 1) as int32) + " has " + description +
				": a seed is a string, a byte array, a Pubkey or an account; " +
				"write an integer seed as bytes: `[x]` for a uint8, " +
				"`leBytes(x)` for a wider integer", element);
		}
		slices.push({
			kind: NodeKind.CallExpr,
			line: line,
			column: column,
			callee: builder!,
			arguments: [argument],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		});
		position = position + 1;
	}
	return { kind: NodeKind.ArrayLiteral, line: list.line, column: list.column, elements: slices };
}
