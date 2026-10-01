import { Node, NodeKind, bindSym } from "std/meta";
import { instructionDiscriminator } from "./discriminator";
import {
	argBool,
	argBoolValid,
	argI16,
	argI32,
	argI64,
	argI8,
	argPubkey,
	argU16,
	argU32,
	argU64,
	argU8,
	argsFit,
} from "./core";

export macro instruction(): Node {
	const decl = getTypeArg();
	if (decl.kind !== NodeKind.EnumDecl) {
		error("instruction<Op>(): Op must be an enum of the program's instructions", decl);
	}
	const bytes: Node[] = [];
	let member = 0;
	while (member < decl.enumMembers.length) {
		const discriminator = instructionDiscriminator(decl.enumMembers[member]);
		let b = 0;
		while (b < 8) {
			const byte = discriminator.bytes[b];
			bytes.push({
				kind: NodeKind.NumberLiteral,
				line: decl.line,
				column: decl.column,
				value: byte as number,
				isFloat: false,
				intVal: byte as int64,
				outOfRangeText: "",
				isBitPattern: false,
			});
			b = b + 1;
		}
		member = member + 1;
	}
	const table: Node = {
		kind: NodeKind.TypeAssertion,
		line: decl.line,
		column: decl.column,
		asExpr: {
			kind: NodeKind.ArrayLiteral,
			line: decl.line,
			column: decl.column,
			elements: bytes,
		},
		asType: "uint8[" + (bytes.length as int32) + "]",
	};
	return {
		kind: NodeKind.CallExpr,
		line: decl.line,
		column: decl.column,
		callee: {
			kind: NodeKind.Identifier,
			line: decl.line,
			column: decl.column,
			name: "selectInstruction",
		},
		arguments: [table],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro args(): Node {
	const shape = getTypeArg();
	if (shape.kind !== NodeKind.TypeObject) {
		error("args<T>(): T must be a struct of the instruction's arguments", shape);
	}
	const values: Node[] = [];
	const checks: Node[] = [];
	let offset = 0;
	let field = 0;
	while (field < shape.typExprFieldNames.length) {
		const written = shape.typExprFieldTypes[field];
		let typeName = "";
		if (written.kind === NodeKind.Identifier) { typeName = written.name; }
		if (written.kind === NodeKind.TypeObject) { typeName = written.typExprTypeName; }
		let width = 0;
		let reader: Node | null = null;
		if (typeName == "uint8") { width = 1; reader = bindSym("argU8"); }
		if (typeName == "int8") { width = 1; reader = bindSym("argI8"); }
		if (typeName == "boolean") { width = 1; reader = bindSym("argBool"); }
		if (typeName == "uint16") { width = 2; reader = bindSym("argU16"); }
		if (typeName == "int16") { width = 2; reader = bindSym("argI16"); }
		if (typeName == "uint32") { width = 4; reader = bindSym("argU32"); }
		if (typeName == "int32") { width = 4; reader = bindSym("argI32"); }
		if (typeName == "uint64") { width = 8; reader = bindSym("argU64"); }
		if (typeName == "int64") { width = 8; reader = bindSym("argI64"); }
		if (typeName == "Pubkey") { width = 32; reader = bindSym("argPubkey"); }
		if (reader == null) {
			error("args<T>(): field '" + shape.typExprFieldNames[field] +
				"' is not fixed-size plain data (sized integer, boolean or Pubkey)", shape);
		}
		const at: Node = {
			kind: NodeKind.NumberLiteral,
			line: shape.line,
			column: shape.column,
			value: offset as number,
			isFloat: false,
			intVal: offset as int64,
			outOfRangeText: "",
			isBitPattern: false,
		};
		values.push({
			kind: NodeKind.CallExpr,
			line: shape.line,
			column: shape.column,
			callee: reader,
			arguments: [at],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		});
		if (typeName == "boolean") {
			checks.push({
				kind: NodeKind.CallExpr,
				line: shape.line,
				column: shape.column,
				callee: bindSym("argBoolValid"),
				arguments: [at],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			});
		}
		offset = offset + width;
		field = field + 1;
	}
	let fits: Node = {
		kind: NodeKind.CallExpr,
		line: shape.line,
		column: shape.column,
		callee: bindSym("argsFit"),
		arguments: [{
			kind: NodeKind.NumberLiteral,
			line: shape.line,
			column: shape.column,
			value: offset as number,
			isFloat: false,
			intVal: offset as int64,
			outOfRangeText: "",
			isBitPattern: false,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
	let check = 0;
	while (check < checks.length) {
		fits = {
			kind: NodeKind.BinaryExpr,
			line: shape.line,
			column: shape.column,
			operator: "&&",
			left: fits,
			right: checks[check],
		};
		check = check + 1;
	}
	return {
		kind: NodeKind.CallExpr,
		line: shape.line,
		column: shape.column,
		callee: {
			kind: NodeKind.Identifier,
			line: shape.line,
			column: shape.column,
			name: "readArgs",
		},
		arguments: [fits, {
			kind: NodeKind.ObjectLiteral,
			line: shape.line,
			column: shape.column,
			properties: values,
			keys: shape.typExprFieldNames,
			keyLocations: [],
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}
