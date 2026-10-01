import { Node, NodeKind, bindSym, getImpl } from "std/meta";
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
	exclusiveWritable,
	mutableAccount,
	ownedAccount,
	programAccount,
	signer,
	systemAccount,
	unchecked,
	writable,
	writableSigner,
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

export macro accounts(): Node {
	const shape = getTypeArg();
	if (shape.kind !== NodeKind.TypeObject) {
		error("accounts<T>(): T must be a struct of the instruction's accounts", shape);
	}
	const decl = getImpl(bindSym(shape.typExprTypeName))!;
	const line = shape.line;
	const column = shape.column;
	const values: Node[] = [];
	let field = 0;
	while (field < decl.interfaceFields.length) {
		const written = decl.interfaceFieldTypes[field];
		const open = written.indexOf("<");
		const base = open < 0 ? written : written.slice(0, open);
		const inner = open < 0 ? "" : written.slice(open + 1, written.length - 1);
		const index: Node = {
			kind: NodeKind.NumberLiteral,
			line: line,
			column: column,
			value: field as number,
			isFloat: false,
			intVal: field as int64,
			outOfRangeText: "",
			isBitPattern: false,
		};
		let callee: Node | null = null;
		let extra: Node[] = [];
		if (base == "Signer") { callee = bindSym("signer"); }
		if (base == "WritableSigner") { callee = bindSym("writableSigner"); }
		if (base == "Writable") { callee = bindSym("writable"); }
		if (base == "SystemAccount") { callee = bindSym("systemAccount"); }
		if (base == "Account") { callee = bindSym("unchecked"); }
		const typeName: Node = {
			kind: NodeKind.Identifier,
			line: line,
			column: column,
			name: inner,
		};
		if (base == "Program") {
			callee = bindSym("programAccount");
			extra = [{
				kind: NodeKind.CallExpr,
				line: line,
				column: column,
				callee: {
					kind: NodeKind.MemberExpr,
					line: line,
					column: column,
					object: typeName,
					property: "id",
					isOptional: false,
				},
				arguments: [],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			}];
		}
		if (base == "Owned" || base == "Mutable") {
			callee = base == "Owned" ? bindSym("ownedAccount") : bindSym("mutableAccount");
			const discriminator: Node = {
				kind: NodeKind.CallExpr,
				line: line,
				column: column,
				callee: {
					kind: NodeKind.MemberExpr,
					line: line,
					column: column,
					object: {
						kind: NodeKind.CallExpr,
						line: line,
						column: column,
						callee: {
							kind: NodeKind.MemberExpr,
							line: line,
							column: column,
							object: typeName,
							property: "discriminator",
							isOptional: false,
						},
						arguments: [],
						isDirectCall: false,
						resolvedOverloadIdx: -1,
					},
					property: "word",
					isOptional: false,
				},
				arguments: [],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			};
			const size: Node = {
				kind: NodeKind.TypeAssertion,
				line: line,
				column: column,
				asExpr: {
					kind: NodeKind.SizeofExpr,
					line: line,
					column: column,
					sizeofType: inner,
				},
				asType: "uint64",
			};
			extra = [discriminator, size];
		}
		let check: Node | null = null;
		if (callee != null) {
			check = {
				kind: NodeKind.CallExpr,
				line: line,
				column: column,
				callee: callee!,
				arguments: [index].concat(extra),
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			};
		}
		if (base == "External" || base == "ExternalMutable") {
			check = {
				kind: NodeKind.CallExpr,
				line: line,
				column: column,
				callee: {
					kind: NodeKind.MemberExpr,
					line: line,
					column: column,
					object: typeName,
					property: "verify",
					isOptional: false,
				},
				arguments: [index],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			};
			if (base == "ExternalMutable") {
				check = {
					kind: NodeKind.CallExpr,
					line: line,
					column: column,
					callee: bindSym("exclusiveWritable"),
					arguments: [{
						kind: NodeKind.TryExpr,
						line: line,
						column: column,
						tryArg: check!,
						hasCatch: false,
						catchVal: check!,
					}],
					isDirectCall: false,
					resolvedOverloadIdx: -1,
				};
			}
		}
		if (check == null) {
			error("accounts<T>(): field '" + decl.interfaceFields[field] + "' has type '" +
				written + "'; use Signer, WritableSigner, Writable, SystemAccount, Account, " +
				"Program<P>, " +
				"Owned<T>, Mutable<T>, External<T> or ExternalMutable<T>", shape);
		}
		values.push({
			kind: NodeKind.TypeAssertion,
			line: line,
			column: column,
			asExpr: {
				kind: NodeKind.TryExpr,
				line: line,
				column: column,
				tryArg: check!,
				hasCatch: false,
				catchVal: check!,
			},
			asType: written,
		});
		field = field + 1;
	}
	return {
		kind: NodeKind.CallExpr,
		line: line,
		column: column,
		callee: { kind: NodeKind.Identifier, line: line, column: column, name: "readArgs" },
		arguments: [{
			kind: NodeKind.BooleanLiteral,
			line: line,
			column: column,
			boolValue: true,
		}, {
			kind: NodeKind.ObjectLiteral,
			line: line,
			column: column,
			properties: values,
			keys: decl.interfaceFields,
			keyLocations: [],
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}
