import { Node, NodeFlag, NodeKind, bindSym, define, getType, stringValue } from "std/meta";
import { eventDiscriminator, instructionDiscriminator } from "./discriminator";
import { derivedAddressOf } from "./pda";
import { Pubkey, pubkeyOf } from "./pubkey";
import { ProgramError } from "./error";
import { readFile } from "std/fs";
import { SEED_LIST_REQUIRED, seedTable } from "./accountSeeds";
import {
	argBool,
	argBoolValid,
	argBytes,
	argBytesFit,
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
	instructionHasDiscriminator,
	instructionHasWord,
	SCRATCH_MAX_COUNT,
	foundSigner,
	logEvent,
	scratchAddress,
	slottedSeeds,
} from "./core";
import {
	createPdaAt,
	createPdaOf,
	createPdaProven,
	readArgs,
	selectLiteralInstruction,
} from "./typed";
import { DELEGATION_MAX_SEEDS, delegateAt } from "./delegation";
import { createMintPdaAt } from "./mint";
import {
	bytesAddress,
	createAddress,
	findAddress,
	ownProgram,
	signerOf,
} from "./seed";

export macro instruction(): Node {
	// The `programId` of the project's build.ms (`defines: { programId: "<base58>" }`), or no bytes.
	function declaredProgramKey(at: Node): uint8[] {
		const text = define("programId");
		const bytes: uint8[] = [];
		if (text == "") return bytes;
		const parsed = Pubkey.parse(text);
		if (!parsed.ok) {
			error("the build declares programId '" + text + "' (build.ms `defines` or -d:programId), which is not a base58 public key", at);
		}
		for (const b of parsed.value.bytes) { bytes.push(b); }
		return bytes;
	}

	const decl = getTypeArg();
	if (decl.kind !== NodeKind.EnumDecl) {
		error("instruction<Op>(): Op must be an enum of the program's instructions", decl);
	}
	// The deploy keypair (`programKeypair`, a solana-keygen JSON of 64 numbers; relative to the
	// project's build.ms) must hold the declared id, as `anchor keys sync` keeps declare_id! equal to it.
	function checkDeployKeypair(at: Node): void {
		const named = define("programKeypair");
		if (named == "") return;
		const root = define("projectDir");
		const path = named.startsWith("/") || root == "" ? named : root + "/" + named;
		const text = try readFile(path) catch "";
		if (text == "") { error("the build names programKeypair '" + path + "', which cannot be read", at); }
		const numbers: uint8[] = [];
		let value = -1;
		for (const c of text.asBytes()) {
			if (c >= 48 && c <= 57) {
				value = (value < 0 ? 0 : value * 10) + (c - 48);
				if (value > 255) { error("programKeypair '" + path + "' holds a number above 255", at); }
			} else if (value >= 0) {
				numbers.push(value as uint8);
				value = -1;
			}
		}
		if (value >= 0) { numbers.push(value as uint8); }
		if (numbers.length != 64) { error("programKeypair '" + path + "' holds " + String(numbers.length) + " numbers; a solana-keygen keypair holds 64", at); }
		let key = Pubkey.zero();
		for (let i = 0; i < 32; i += 1) { key.bytes[i] = numbers[32 + i]; }
		const held = key.toBase58();
		const declaredText = define("programId");
		if (declaredText == "") {
			error("the deploy keypair '" + path + "' is program " + held + ", and the build declares no programId: add `programId: \"" + held + "\"` to the defines of build.ms", at);
		}
		if (declaredText != held) {
			error("the build declares programId " + declaredText + ", but the deploy keypair '" + path + "' is program " + held
				+ ": set programId to " + held + ", or deploy with the keypair of " + declaredText, at);
		}
	}

	function ordinal(value: int32): Node {
		return { kind: NodeKind.NumberLiteral, line: decl.line, column: decl.column,
			value: value as number, intVal: value as int64, isFloat: false, isBitPattern: false, outOfRangeText: "" };
	}
	function word(bytes: Readonly<Span<uint8>>, offset: int32): Node {
		let value: uint64 = 0;
		for (let b = 0; b < 8; b++) { value |= (bytes[offset + b] as uint64) << ((b * 8) as uint64); }
		return { kind: NodeKind.TypeAssertion, line: decl.line, column: decl.column, asType: "uint64",
			asExpr: { kind: NodeKind.NumberLiteral, line: decl.line, column: decl.column,
				value: (value as int64) as number, intVal: value as int64, isFloat: false, isBitPattern: true, outOfRangeText: "" } };
	}
	function call(callee: Node, arguments: Node[]): Node {
		return { kind: NodeKind.CallExpr, line: decl.line, column: decl.column,
			callee, arguments, isDirectCall: false, resolvedOverloadIdx: -1 };
	}
	function choose(condition: Node, yes: Node, no: Node): Node {
		return { kind: NodeKind.ConditionalExpr, line: decl.line, column: decl.column,
			ternaryCondition: condition, ternaryConsequent: yes, ternaryAlternate: no };
	}
	checkDeployKeypair(decl);
	declaredProgramKey(decl);
	let selected = ordinal(-(ProgramError.instructionFallbackNotFound().code as int32));
	for (let member = decl.enumMembers.length - 1; member >= 0; member--) {
		const tag = instructionDiscriminator(decl.enumMembers[member]);
		selected = choose(call(bindSym("instructionHasWord"), [word(tag.bytes, 0)]), ordinal(member), selected);
	}
	selected = choose(call(bindSym("instructionHasDiscriminator"), []), selected, ordinal(-(ProgramError.instructionMissing().code as int32)));
	return {
		kind: NodeKind.CallExpr,
		line: decl.line,
		column: decl.column,
		callee: {
			kind: NodeKind.TypeGeneric,
			typExprBase: bindSym("selectLiteralInstruction")!,
			typExprArgs: [getTypeArg()],
		},
		arguments: [selected],
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
		let count = -1;
		if (written.kind === NodeKind.TypeArray && written.typExprSize >= 0) {
			count = written.typExprSize as int32;
			const element = written.typExprElement;
			if (element.kind === NodeKind.Identifier) { typeName = element.name; }
			if (element.kind === NodeKind.TypeObject) { typeName = element.typExprTypeName; }
		}
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
		const fixedPubkeyBytes = count == 32 && typeName == "uint8";
		if (fixedPubkeyBytes) { reader = bindSym("argPubkey"); }
		if (typeName == "Bytes" && count < 0) {
			if (field != shape.typExprFieldNames.length - 1) {
				error("args<T>(): Bytes field '" + shape.typExprFieldNames[field] +
					"' must be the last field: Borsh prefixes it with its length", shape);
			}
			width = 4;
			reader = bindSym("argBytes");
		}
		if (reader == null || (count >= 0 && typeName == "Bytes")) {
			error("args<T>(): field '" + shape.typExprFieldNames[field] +
				"' is not a sized integer, boolean, Pubkey, a fixed array of those or a last Bytes field", shape);
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
		let decoded: Node = {
			kind: NodeKind.CallExpr,
			line: shape.line,
			column: shape.column,
			callee: reader,
			arguments: [at],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
		if (count >= 0 && !fixedPubkeyBytes) {
			const elements: Node[] = [];
			for (let i = 0; i < count; i++) {
				elements.push({
					kind: NodeKind.CallExpr,
					line: shape.line,
					column: shape.column,
					callee: reader,
					arguments: [{
						kind: NodeKind.NumberLiteral,
						line: shape.line,
						column: shape.column,
						value: (offset + i * width) as number,
						intVal: (offset + i * width) as int64,
						isFloat: false,
						isBitPattern: false,
						outOfRangeText: "",
					}],
					isDirectCall: false,
					resolvedOverloadIdx: -1,
				});
				if (typeName == "boolean") {
					checks.push({
						kind: NodeKind.CallExpr,
						callee: bindSym("argBoolValid"),
						arguments: elements[i].arguments,
						isDirectCall: false,
						resolvedOverloadIdx: -1,
					});
				}
			}
			decoded = typeName == "Pubkey" ? {
				kind: NodeKind.ArrayLiteral,
				elements,
			} : {
				kind: NodeKind.TypeAssertion,
				line: shape.line,
				column: shape.column,
				asType: typeName + "[" + String(count) + "]",
				asExpr: { kind: NodeKind.ArrayLiteral, elements },
			};
		}
		values.push(fixedPubkeyBytes ? {
			kind: NodeKind.MemberExpr,
			object: decoded,
			property: "bytes",
			isOptional: false,
		} : decoded);
		if (count < 0 && (typeName == "boolean" || typeName == "Bytes")) {
			checks.push({
				kind: NodeKind.CallExpr,
				line: shape.line,
				column: shape.column,
				callee: typeName == "Bytes" ? bindSym("argBytesFit") : bindSym("argBoolValid"),
				arguments: [at],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			});
		}
		offset = offset + width * (count >= 0 ? count : 1);
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
			kind: NodeKind.TypeGeneric,
			typExprBase: bindSym("readArgs")!,
			typExprArgs: [getTypeArg()],
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


export macro seeds(use: Node): Node {
	error("@seeds is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro bump(use: Node): Node {
	error("@bump is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro hasOne(use: Node): Node {
	error("@hasOne is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro address(use: Node): Node {
	error("@address is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro associated(use: Node): Node {
	error("@associated is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro constraint(use: Node): Node {
	error("@constraint is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro tokenMint(use: Node): Node {
	error("@tokenMint is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro tokenAuthority(use: Node): Node {
	error("@tokenAuthority is a field decorator that accounts<T>() reads; it is not called", use);
}

export macro scratch(count: Node): Node {
	const element = getTypeArg();
	let typeName = "";
	if (element.kind === NodeKind.Identifier) { typeName = element.name; }
	if (element.kind === NodeKind.TypeObject) { typeName = element.typExprTypeName; }
	if (typeName == "") {
		error("scratch<T>(count): T is a named type with no managed memory: a number, boolean, Pubkey, " +
			"or a struct or fixed array of those", element);
	}
	function readsTwice(value: Node): boolean {
		if (value.kind === NodeKind.NumberLiteral || value.kind === NodeKind.Identifier) { return true; }
		if (value.kind === NodeKind.MemberExpr) { return readsTwice(value.object); }
		if (value.kind === NodeKind.TypeAssertion) { return readsTwice(value.asExpr); }
		if (value.kind === NodeKind.BinaryExpr) { return readsTwice(value.left) && readsTwice(value.right); }
		return false;
	}
	if (!readsTwice(count)) {
		error("scratch<T>(count): count is evaluated twice, so it is made of numbers, locals, fields, casts and " +
			"arithmetic; bind a call to a const first", count);
	}
	const line = count.line;
	const column = count.column;
	const address: Node = {
		kind: NodeKind.CallExpr,
		line: line,
		column: column,
		callee: bindSym("scratchAddress"),
		arguments: [{ kind: NodeKind.TypeAssertion, line: line, column: column, asExpr: count, asType: "uint64" }],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
	address.typeArg = typeName;
	const found: Node = { kind: NodeKind.TryExpr, line: line, column: column, tryArg: address, hasCatch: false, catchVal: address };
	const pointer: Node = {
		kind: NodeKind.TypeAssertion,
		line: line,
		column: column,
		asExpr: found,
		asType: "Ptr<" + typeName + "[" + String(SCRATCH_MAX_COUNT as int32) + "]>",
	};
	const whole: Node = { kind: NodeKind.HiddenDeref, line: line, column: column, expr: pointer };
	whole.flags = whole.flags.incl(NodeFlag.ExplicitDeref);
	const zero: Node = {
		kind: NodeKind.NumberLiteral,
		line: line,
		column: column,
		value: 0,
		isFloat: false,
		intVal: 0,
		outOfRangeText: "",
		isBitPattern: false,
	};
	const range: Node = { kind: NodeKind.BinaryExpr, line: line, column: column, operator: "..", left: zero, right: count };
	return { kind: NodeKind.ArrayAccess, line: line, column: column, array: whole, index: range };
}

export macro emit(value: Node): Node {
	const shape = getTypeArg();
	if (shape.kind !== NodeKind.TypeObject) {
		error("emit<E>(value): E must be the event struct", shape);
	}
	if (value.kind !== NodeKind.Identifier) {
		error("emit<E>(value): pass the event as a local variable", value);
	}
	const line = value.line;
	const column = value.column;
	const discriminator = eventDiscriminator(shape.typExprTypeName);
	const bytes: Node[] = [];
	let b = 0;
	while (b < 8) {
		const byte = discriminator.bytes[b];
		bytes.push({
			kind: NodeKind.NumberLiteral,
			line: line,
			column: column,
			value: byte as number,
			isFloat: false,
			intVal: byte as int64,
			outOfRangeText: "",
			isBitPattern: false,
		});
		b = b + 1;
	}
	const widths: Node[] = [];
	const words: Node[] = [];
	let total = 8;
	let field = 0;
	while (field < shape.typExprFieldNames.length) {
		const written = shape.typExprFieldTypes[field];
		let typeName = "";
		if (written.kind === NodeKind.Identifier) { typeName = written.name; }
		if (written.kind === NodeKind.TypeObject) { typeName = written.typExprTypeName; }
		let width = 0;
		if (typeName == "uint8" || typeName == "int8" || typeName == "boolean") { width = 1; }
		if (typeName == "uint16" || typeName == "int16") { width = 2; }
		if (typeName == "uint32" || typeName == "int32") { width = 4; }
		if (typeName == "uint64" || typeName == "int64") { width = 8; }
		if (typeName == "Pubkey") { width = 32; }
		if (width == 0) {
			error("emit<E>(value): field '" + shape.typExprFieldNames[field] +
				"' is not fixed-size plain data (sized integer, boolean or Pubkey)", shape);
		}
		const member: Node = {
			kind: NodeKind.MemberExpr,
			line: line,
			column: column,
			object: { kind: NodeKind.Identifier, line: line, column: column, name: value.name },
			property: shape.typExprFieldNames[field],
			isOptional: false,
		};
		let word: Node = {
			kind: NodeKind.TypeAssertion,
			line: line,
			column: column,
			asExpr: member,
			asType: "uint64",
		};
		if (typeName == "boolean") {
			word = {
				kind: NodeKind.TypeAssertion,
				line: line,
				column: column,
				asExpr: {
					kind: NodeKind.ConditionalExpr,
					line: line,
					column: column,
					ternaryCondition: member,
					ternaryConsequent: {
						kind: NodeKind.NumberLiteral,
						line: line,
						column: column,
						value: 1,
						isFloat: false,
						intVal: 1,
						outOfRangeText: "",
						isBitPattern: false,
					},
					ternaryAlternate: {
						kind: NodeKind.NumberLiteral,
						line: line,
						column: column,
						value: 0,
						isFloat: false,
						intVal: 0,
						outOfRangeText: "",
						isBitPattern: false,
					},
				},
				asType: "uint64",
			};
		}
		if (typeName == "Pubkey") {
			word = {
				kind: NodeKind.CallExpr,
				line: line,
				column: column,
				callee: bindSym("bytesAddress"),
				arguments: [{
					kind: NodeKind.MemberExpr,
					line: line,
					column: column,
					object: member,
					property: "bytes",
					isOptional: false,
				}],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			};
		}
		widths.push({
			kind: NodeKind.NumberLiteral,
			line: line,
			column: column,
			value: width as number,
			isFloat: false,
			intVal: width as int64,
			outOfRangeText: "",
			isBitPattern: false,
		});
		words.push(word);
		total = total + width;
		field = field + 1;
	}
	if (total > 1024) {
		error("emit<E>(value): the event is " + (total as int32) +
			" bytes with its discriminator, over the 1024 the std buffers", shape);
	}
	const count = widths.length;
	return {
		kind: NodeKind.TypeAssertion,
		line: line,
		column: column,
		asExpr: {
			kind: NodeKind.CallExpr,
			line: line,
			column: column,
			callee: bindSym("logEvent"),
			arguments: [{
				kind: NodeKind.TypeAssertion,
				line: line,
				column: column,
				asExpr: { kind: NodeKind.ArrayLiteral, line: line, column: column, elements: bytes },
				asType: "uint8[8]",
			}, {
				kind: NodeKind.TypeAssertion,
				line: line,
				column: column,
				asExpr: { kind: NodeKind.ArrayLiteral, line: line, column: column, elements: widths },
				asType: "uint8[" + (count as int32) + "]",
			}, {
				kind: NodeKind.TypeAssertion,
				line: line,
				column: column,
				asExpr: { kind: NodeKind.ArrayLiteral, line: line, column: column, elements: words },
				asType: "uint64[" + (count as int32) + "]",
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		},
		asType: "uint64",
	};
}


export macro programAddress(seeds: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: seeds.line,
		column: seeds.column,
		callee: bindSym("createAddress"),
		arguments: [{
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, {
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("ownProgram"),
			arguments: [],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro programAddressOf(program: Node, seeds: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: seeds.line,
		column: seeds.column,
		callee: bindSym("createAddress"),
		arguments: [{
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, {
			kind: NodeKind.CallExpr,
			line: program.line,
			column: program.column,
			callee: bindSym("bytesAddress"),
			arguments: [{
				kind: NodeKind.MemberExpr,
				line: program.line,
				column: program.column,
				object: program,
				property: "bytes",
				isOptional: false,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro findProgramAddress(seeds: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: seeds.line,
		column: seeds.column,
		callee: bindSym("findAddress"),
		arguments: [{
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, {
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("ownProgram"),
			arguments: [],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro findProgramAddressOf(program: Node, seeds: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: seeds.line,
		column: seeds.column,
		callee: bindSym("findAddress"),
		arguments: [{
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, {
			kind: NodeKind.CallExpr,
			line: program.line,
			column: program.column,
			callee: bindSym("bytesAddress"),
			arguments: [{
				kind: NodeKind.MemberExpr,
				line: program.line,
				column: program.column,
				object: program,
				property: "bytes",
				isOptional: false,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro pda(account: Node, seeds: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: account.line,
		column: account.column,
		callee: {
			kind: NodeKind.MemberExpr,
			line: account.line,
			column: account.column,
			object: account,
			property: "verifiedPda",
			isOptional: false,
		},
		arguments: [{
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro pdaWithBump(account: Node, seeds: Node, bump: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: account.line,
		column: account.column,
		callee: {
			kind: NodeKind.MemberExpr,
			line: account.line,
			column: account.column,
			object: account,
			property: "verifiedPdaWithBump",
			isOptional: false,
		},
		arguments: [{
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, bump],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro createPda(payer: Node, target: Node, seeds: Node): Node {
	// The bytes of each seed when every one is a string or a byte list written in place, else none.
	function literalSeeds(seeds: Node): uint8[][] {
		const out: uint8[][] = [];
		if (seeds.kind !== NodeKind.ArrayLiteral) return [];
		for (const seed of seeds.elements) {
			const bytes: uint8[] = [];
			if (seed.kind === NodeKind.StringLiteral) {
				for (const byte of stringValue(seed).asBytes()) { bytes.push(byte); }
			} else if (seed.kind === NodeKind.ArrayLiteral) {
				for (const element of seed.elements) {
					if (element.kind !== NodeKind.NumberLiteral || element.intVal < 0 || element.intVal > 255) return [];
					bytes.push(element.intVal as uint8);
				}
			} else {
				return [];
			}
			out.push(bytes);
		}
		return out;
	}

		function byteLiteral(value: uint8, at: Node): Node {
			return {
				kind: NodeKind.NumberLiteral,
				line: at.line,
				column: at.column,
				value: value as number,
				isFloat: false,
				intVal: value as int64,
				outOfRangeText: "",
				isBitPattern: false,
			};
		}

		// The `programId` of the project's build.ms (`defines: { programId: "<base58>" }`), or no bytes.
		function declaredProgramKey(at: Node): uint8[] {
			const text = define("programId");
			const bytes: uint8[] = [];
			if (text == "") return bytes;
			const parsed = Pubkey.parse(text);
			if (!parsed.ok) {
				error("the build declares programId '" + text + "' (build.ms `defines` or -d:programId), which is not a base58 public key", at);
			}
			for (const b of parsed.value.bytes) { bytes.push(b); }
			return bytes;
		}

	const targetType = getType(target);
	let targetName = "";
	if (targetType != null && targetType.kind === NodeKind.Identifier) { targetName = targetType.name; }
	if (targetType != null && targetType.kind === NodeKind.TypeObject) { targetName = targetType.typExprTypeName; }
	if (targetName == "WritablePda") {
		return {
			kind: NodeKind.CallExpr,
			line: payer.line,
			column: payer.column,
			callee: {
				kind: NodeKind.TypeGeneric,
				typExprBase: bindSym("createPdaProven")!,
				typExprArgs: [getTypeArg()],
			},
			arguments: [payer, target, {
				kind: NodeKind.CallExpr,
				line: seeds.line,
				column: seeds.column,
				callee: bindSym("seedTable"),
				arguments: [seeds],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
	}
	const declared = declaredProgramKey(seeds);
	const literal = declared.length > 0 ? literalSeeds(seeds) : [];
	if (literal.length > 0) {
		let program: Pubkey = { bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] };
		for (let i = 0; i < 32; i += 1) { program.bytes[i] = declared[i]; }
		const found = derivedAddressOf(literal, program);
		if (!found.ok) { error("createPda: these seeds give no program address for the programId of build.ms", seeds); }
		const words: Node[] = [];
		for (let w = 0; w < 4; w += 1) {
			let word: uint64 = 0;
			for (let b = 7; b >= 0; b -= 1) { word = (word << 8) | (found.value.key.bytes[w * 8 + b] as uint64); }
			words.push({
				kind: NodeKind.NumberLiteral,
				line: seeds.line,
				column: seeds.column,
				value: word as number,
				isFloat: false,
				intVal: word as int64,
				outOfRangeText: "",
				isBitPattern: true,
			});
		}
		const bumped: Node[] = [];
		for (const seed of seeds.elements) { bumped.push(seed); }
		bumped.push({ kind: NodeKind.ArrayLiteral, line: seeds.line, column: seeds.column, elements: [byteLiteral(found.value.bump, seeds)] });
		return {
			kind: NodeKind.CallExpr,
			line: payer.line,
			column: payer.column,
			callee: {
				kind: NodeKind.TypeGeneric,
				typExprBase: bindSym("createPdaAt")!,
				typExprArgs: [getTypeArg()],
			},
			arguments: [payer, target, {
				kind: NodeKind.CallExpr,
				line: seeds.line,
				column: seeds.column,
				callee: bindSym("seedTable"),
				arguments: [{ kind: NodeKind.ArrayLiteral, line: seeds.line, column: seeds.column, elements: bumped }],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			}, words[0], words[1], words[2], words[3], byteLiteral(found.value.bump, seeds)],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
	}
	let slotted: Node = seeds;
	if (seeds.kind === NodeKind.ArrayLiteral) {
		const elements: Node[] = [];
		for (const seed of seeds.elements) { elements.push(seed); }
		elements.push({ kind: NodeKind.ArrayLiteral, line: seeds.line, column: seeds.column, elements: [byteLiteral(0, seeds)] });
		slotted = { kind: NodeKind.ArrayLiteral, line: seeds.line, column: seeds.column, elements: elements };
	}
	return {
		kind: NodeKind.CallExpr,
		line: payer.line,
		column: payer.column,
		callee: {
			kind: NodeKind.TypeGeneric,
			typExprBase: bindSym("createPdaOf")!,
			typExprArgs: [getTypeArg()],
		},
		arguments: [payer, target, {
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("slottedSeeds"),
			arguments: [{
				kind: NodeKind.CallExpr,
				line: seeds.line,
				column: seeds.column,
				callee: bindSym("seedTable"),
				arguments: [slotted],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

// The program id the build declares (build.ms `defines: { programId }`, or -d:programId), as a
// Pubkey folded at compile time; host tests run the program under it.
export macro declaredProgramId(): Node {
	const at: Node = { kind: NodeKind.Identifier, line: 0, column: 0, name: "declaredProgramId" };
	const text = define("programId");
	if (text == "") {
		error("declaredProgramId(): the build declares no programId; add `defines: { programId: \"<base58>\" }` to build.ms, or pass -d:programId=<base58>", at);
	}
	return {
		kind: NodeKind.CallExpr,
		line: at.line,
		column: at.column,
		callee: bindSym("pubkeyOf"),
		arguments: [{ kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: text }],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro createMintPda(
	payer: Node,
	mint: Node,
	seeds: Node,
	program: Node,
	decimals: Node,
	mintAuthority: Node,
	freezeAuthority: Node,
): Node {
	return {
		kind: NodeKind.CallExpr,
		line: payer.line,
		column: payer.column,
		callee: bindSym("createMintPdaAt"),
		arguments: [payer, mint, {
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, program, decimals, mintAuthority, freezeAuthority],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro signedPda(call: Node, pda: Node, seeds: Node): Node {
	// The signer table of one PDA, found where the call that signs with it is written: a failure of the find
	// returns from the enclosing function before the call runs.
	function foundSigning(pda: Node, seeds: Node): Node {
		const slot: Node = {
			kind: NodeKind.NumberLiteral,
			line: seeds.line,
			column: seeds.column,
			value: 0,
			isFloat: false,
			intVal: 0,
			outOfRangeText: "",
			isBitPattern: false,
		};
		const elements: Node[] = [];
		for (const seed of seeds.elements) { elements.push(seed); }
		elements.push({ kind: NodeKind.ArrayLiteral, line: seeds.line, column: seeds.column, elements: [slot] });
		const slotted: Node = { kind: NodeKind.ArrayLiteral, line: seeds.line, column: seeds.column, elements: elements };
		const found: Node = {
			kind: NodeKind.CallExpr,
			line: pda.line,
			column: pda.column,
			callee: bindSym("foundSigner"),
			arguments: [pda, {
				kind: NodeKind.CallExpr,
				line: seeds.line,
				column: seeds.column,
				callee: bindSym("slottedSeeds"),
				arguments: [{
					kind: NodeKind.CallExpr,
					line: seeds.line,
					column: seeds.column,
					callee: bindSym("seedTable"),
					arguments: [slotted],
					isDirectCall: false,
					resolvedOverloadIdx: -1,
				}],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
		return { kind: NodeKind.TryExpr, line: pda.line, column: pda.column, tryArg: found, hasCatch: false, catchVal: found };
	}

	const plain = pda.kind === NodeKind.NullLiteral;
	if (call.kind !== NodeKind.CallExpr) {
		error("signed(call, seeds): the first argument is the call that signs, written " +
			"with its own arguments: signed(transfer(from, to, 10), [\"vault\", [bump]])", call);
	}
	let callee: Node = call.callee;
	let calleeName = "the callee";
	if (callee.kind === NodeKind.Identifier) {
		calleeName = callee.name;
	}
	if (callee.kind === NodeKind.MemberExpr) {
		calleeName = callee.property;
		callee = {
			kind: NodeKind.MemberExpr,
			line: callee.line,
			column: callee.column,
			object: callee.object,
			property: callee.property,
			isOptional: callee.isOptional,
		};
	}
	const shape = getType(call.callee);
	let takesSigners = false;
	if (shape != null && shape.kind === NodeKind.TypeFunction && shape.typExprParams.length > 0) {
		const last = shape.typExprParams[shape.typExprParams.length - 1];
		if (last.kind === NodeKind.TypeArray) {
			const element = last.typExprElement;
			takesSigners = element.kind === NodeKind.TypeObject &&
				element.typExprTypeName == "SignerSeeds";
		}
	}
	if (!takesSigners) {
		error("signed(call, seeds): " + calleeName + " takes no signers; only a call whose last " +
			"parameter is `signers: Readonly<Span<SignerSeeds>>` can be signed", call);
	}
	if (seeds.kind !== NodeKind.ArrayLiteral) { error(SEED_LIST_REQUIRED, seeds); }
	if (seeds.elements.length == 0) {
		error("signed(call, seeds): a signer needs at least one seed", seeds);
	}
	let signers = 0;
	let position = 0;
	while (position < seeds.elements.length) {
		const candidate = seeds.elements[position];
		let holdsSeeds = false;
		if (candidate.kind === NodeKind.ArrayLiteral) {
			let inner = 0;
			while (inner < candidate.elements.length) {
				const seed = candidate.elements[inner];
				const written = getType(seed);
				let isByte = seed.kind === NodeKind.NumberLiteral;
				if (!isByte && written != null && written.kind === NodeKind.Identifier) {
					isByte = written.name == "uint8" || written.name == "int8";
				}
				if (!isByte) { holdsSeeds = true; }
				inner = inner + 1;
			}
		}
		if (holdsSeeds) { signers = signers + 1; }
		position = position + 1;
	}
	if (signers != 0 && signers != seeds.elements.length) {
		error("signed(call, seeds): a list of signers holds only lists of seeds, " +
			"and this list also holds a seed", seeds);
	}
	const lists: Node[] = signers == 0 ? [seeds] : seeds.elements;
	const table: Node[] = [];
	if (!plain) {
		if (signers != 0) {
			error("signedPda(call, pda, seeds): one PDA signs, so the seeds are one list of seeds " +
				"without the bump, and this is a list of signers", seeds);
		}
		table.push(foundSigning(pda, seeds));
	}
	position = 0;
	while (plain && position < lists.length) {
		const list = lists[position];
		table.push({
			kind: NodeKind.CallExpr,
			line: list.line,
			column: list.column,
			callee: bindSym("signerOf"),
			arguments: [{
				kind: NodeKind.CallExpr,
				line: list.line,
				column: list.column,
				callee: bindSym("seedTable"),
				arguments: [list],
				isDirectCall: false,
				resolvedOverloadIdx: -1,
			}],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		});
		position = position + 1;
	}
	const kept: Node[] = [];
	position = 0;
	while (position < call.arguments.length - 1) {
		kept.push(call.arguments[position]);
		position = position + 1;
	}
	const signing: Node = {
		kind: NodeKind.CallExpr,
		line: call.line,
		column: call.column,
		callee: callee,
		arguments: kept.concat([{
			kind: NodeKind.ArrayLiteral,
			line: seeds.line,
			column: seeds.column,
			elements: table,
		}]),
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
	signing.typeArg = call.typeArg;
	return signing;
}

export macro signed(call: Node, seeds: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: call.line,
		column: call.column,
		callee: bindSym("signedPda"),
		arguments: [call, { kind: NodeKind.NullLiteral, line: call.line, column: call.column, nullPlaceholder: true }, seeds],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

export macro delegate(accounts: Node, seeds: Node, bump: Node, config: Node): Node {
	if (seeds.kind === NodeKind.ArrayLiteral &&
		(seeds.elements.length == 0 || (seeds.elements.length as uint64) > DELEGATION_MAX_SEEDS)) {
		error("delegate(): the delegation program takes 1 to " + (DELEGATION_MAX_SEEDS as int32) +
			" seeds, and this list has " + (seeds.elements.length as int32), seeds);
	}
	return {
		kind: NodeKind.CallExpr,
		line: accounts.line,
		column: accounts.column,
		callee: bindSym("delegateAt"),
		arguments: [accounts, {
			kind: NodeKind.CallExpr,
			line: seeds.line,
			column: seeds.column,
			callee: bindSym("seedTable"),
			arguments: [seeds],
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		}, bump, config],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}
