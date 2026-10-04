import { DeclKind, Node, NodeKind, bindSym, getImpl } from "std/meta";
import { eventDiscriminator, instructionDiscriminator } from "./discriminator";
import { ProgramError } from "./error";
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
	delegatedAccount,
	exclusiveWritable,
	holds,
	keysEqual,
	keysMatch,
	logEvent,
	mutableAccount,
	ownedAccount,
	programAccount,
	seedsCanonical,
	seedsGiven,
	signer,
	systemAccount,
	unchecked,
	writable,
	writableSigner,
} from "./core";
import { createPdaOf, readArgs, selectInstruction, wordOf } from "./typed";
import { delegateAt } from "./delegation";
import {
	associatedMatches,
	createMintPdaAt,
	tokenAuthorityMatches,
	tokenMintMatches,
} from "./mint";
import {
	bytesAddress,
	createAddress,
	findAddress,
	ownProgram,
	seedBytes,
	seedKey,
	seedText,
	signerOf,
} from "./seed";

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
		callee: bindSym("selectInstruction"),
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
		if (typeName == "Bytes") {
			if (field != shape.typExprFieldNames.length - 1) {
				error("args<T>(): Bytes field '" + shape.typExprFieldNames[field] +
					"' must be the last field: Borsh prefixes it with its length", shape);
			}
			width = 4;
			reader = bindSym("argBytes");
		}
		if (reader == null) {
			error("args<T>(): field '" + shape.typExprFieldNames[field] +
				"' is not a sized integer, boolean, Pubkey or a last Bytes field", shape);
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
		if (typeName == "boolean" || typeName == "Bytes") {
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
		callee: bindSym("readArgs"),
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
	const holder = "$accounts";
	const names = decl.interfaceFields;

	function ident(name: string, at: Node): Node {
		return { kind: NodeKind.Identifier, line: at.line, column: at.column, name: name };
	}

	function member(object: Node, property: string, at: Node): Node {
		return {
			kind: NodeKind.MemberExpr,
			line: at.line,
			column: at.column,
			object: object,
			property: property,
			isOptional: false,
		};
	}

	function call(callee: Node, args: Node[], at: Node): Node {
		return {
			kind: NodeKind.CallExpr,
			line: at.line,
			column: at.column,
			callee: callee,
			arguments: args,
			isDirectCall: false,
			resolvedOverloadIdx: -1,
		};
	}

	function whole(value: number, at: Node): Node {
		return {
			kind: NodeKind.NumberLiteral,
			line: at.line,
			column: at.column,
			value: value,
			isFloat: false,
			intVal: value as int64,
			outOfRangeText: "",
			isBitPattern: false,
		};
	}

	function attempt(expr: Node, at: Node): Node {
		return {
			kind: NodeKind.ExprStmt,
			line: at.line,
			column: at.column,
			expr: {
				kind: NodeKind.TryExpr,
				line: at.line,
				column: at.column,
				tryArg: expr,
				hasCatch: false,
				catchVal: expr,
			},
		};
	}

	function fieldIndex(name: string): number {
		let at = 0;
		while (at < names.length) {
			if (names[at] == name) { return at; }
			at = at + 1;
		}
		return -1;
	}

	function dataFieldOf(owner: number, property: string, at: Node): boolean {
		const written = decl.interfaceFieldTypes[owner];
		const open = written.indexOf("<");
		if (open < 0) { return false; }
		const outer = written.slice(0, open);
		if (outer != "Owned" && outer != "Mutable" && outer != "Delegated") { return false; }
		const target = getImpl(bindSym(written.slice(open + 1, written.length - 1)));
		if (target == null) {
			error("accounts<" + decl.interfaceName + ">(): field '" + names[owner] +
				"' holds '" + written + "', whose fields are not visible where accounts<T>() is " +
				"called: import the struct", at);
		}
		let member = 0;
		while (member < target!.interfaceFields.length) {
			if (target!.interfaceFields[member] == property) { return true; }
			member = member + 1;
		}
		return false;
	}

	function rewrite(n: Node): Node {
		if (n.kind === NodeKind.Identifier) {
			const owner = fieldIndex(n.name);
			if (owner < 0) { return n; }
			return member(ident(holder, n), n.name, n);
		}
		if (n.kind === NodeKind.MemberExpr) {
			if (n.object.kind === NodeKind.Identifier) {
				const owner = fieldIndex(n.object.name);
				if (owner >= 0 && dataFieldOf(owner, n.property, n)) {
					const proof = member(ident(holder, n), n.object.name, n);
					return member(call(member(proof, "data", n), [], n), n.property, n);
				}
			}
			return member(rewrite(n.object), n.property, n);
		}
		if (n.kind === NodeKind.CallExpr) {
			const args: Node[] = [];
			let position = 0;
			while (position < n.arguments.length) {
				args.push(rewrite(n.arguments[position]));
				position = position + 1;
			}
			const rebuilt = call(rewrite(n.callee), args, n);
			rebuilt.typeArg = n.typeArg;
			return rebuilt;
		}
		if (n.kind === NodeKind.BinaryExpr) {
			return {
				kind: NodeKind.BinaryExpr,
				line: n.line,
				column: n.column,
				operator: n.operator,
				left: rewrite(n.left),
				right: rewrite(n.right),
			};
		}
		if (n.kind === NodeKind.UnaryExpr) {
			return {
				kind: NodeKind.UnaryExpr,
				line: n.line,
				column: n.column,
				unaryOp: n.unaryOp,
				operand: rewrite(n.operand),
			};
		}
		if (n.kind === NodeKind.ConditionalExpr) {
			return {
				kind: NodeKind.ConditionalExpr,
				line: n.line,
				column: n.column,
				ternaryCondition: rewrite(n.ternaryCondition),
				ternaryConsequent: rewrite(n.ternaryConsequent),
				ternaryAlternate: rewrite(n.ternaryAlternate),
			};
		}
		if (n.kind === NodeKind.TypeAssertion) {
			return {
				kind: NodeKind.TypeAssertion,
				line: n.line,
				column: n.column,
				asExpr: rewrite(n.asExpr),
				asType: n.asType,
			};
		}
		if (n.kind === NodeKind.ArrayLiteral) {
			const elements: Node[] = [];
			let position = 0;
			while (position < n.elements.length) {
				elements.push(rewrite(n.elements[position]));
				position = position + 1;
			}
			return { kind: NodeKind.ArrayLiteral, line: n.line, column: n.column, elements: elements };
		}
		if (n.kind === NodeKind.NumberLiteral || n.kind === NodeKind.StringLiteral ||
			n.kind === NodeKind.BooleanLiteral || n.kind === NodeKind.NullLiteral) {
			return n;
		}
		error("accounts<" + decl.interfaceName + ">(): a decorator argument of this form is not " +
			"supported; write an account, a field of its data, a call, an operator, a cast or a " +
			"literal", n);
	}

	function keyOf(n: Node): Node {
		return call(bindSym("keyAddressOf")!, [rewrite(n)], n);
	}

	// Anchor builds a custom error inside the failing branch (anchor-syn-0.31.1 constraints.rs:
	// has_one 297-334, address 172-190, constraint 348-356); a success must not evaluate it.
	function lazily(passed: Node, error: Node, at: Node): Node {
		const refuse = attempt(call(bindSym("holds")!, [{
			kind: NodeKind.BooleanLiteral,
			line: at.line,
			column: at.column,
			boolValue: false,
		}, member(rewrite(error), "code", at)], at), at);
		return {
			kind: NodeKind.IfStmt,
			line: at.line,
			column: at.column,
			condition: {
				kind: NodeKind.UnaryExpr,
				line: at.line,
				column: at.column,
				unaryOp: "!",
				operand: passed,
			},
			consequent: { kind: NodeKind.BlockStmt, line: at.line, column: at.column, statements: [refuse] },
		};
	}

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
		if (base == "Owned" || base == "Mutable" || base == "Delegated") {
			callee = bindSym("ownedAccount");
			if (base == "Mutable") { callee = bindSym("mutableAccount"); }
			if (base == "Delegated") { callee = bindSym("delegatedAccount"); }
			// Read at run time: a @comptime block calls the first overload of `discriminator` for every
			// account type (compiler card 2026-10-04-comptime-block-calls-the-first-overload-by-name).
			const discriminator: Node = {
				kind: NodeKind.CallExpr,
				line: line,
				column: column,
				callee: bindSym("wordOf"),
				arguments: [{
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
				}],
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
				"Owned<T>, Mutable<T>, Delegated<T>, External<T> or ExternalMutable<T>", shape);
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
	const checks: Node[] = [];
	let owner = 0;
	while (owner < names.length) {
		const self = names[owner];
		const selfType = decl.interfaceFieldTypes[owner];
		const isToken = selfType == "External<TokenAccount>" || selfType == "ExternalMutable<TokenAccount>";
		const decorators = decl.interfaceFieldDecorators[owner];
		let seeded: Node | null = null;
		let bumped: Node | null = null;
		const associated: Node[] = [];
		const related: Node[] = [];
		const required: Node[] = [];
		const addressed: Node[] = [];
		const authorized: Node[] = [];
		const minted: Node[] = [];
		let position = 0;
		while (position < decorators.length) {
			const d = decorators[position];
			const name = d.macroName;
			const args = d.macroArgs;
			const where = "accounts<" + decl.interfaceName + ">(): @" + name + " on field '" + self + "'";
			position = position + 1;
			if (name == "seeds") {
				if (seeded != null) { error(where + ": @seeds is written twice", d); }
				if (args.length == 0) { error(where + " needs at least one seed", d); }
				seeded = d;
				continue;
			}
			if (name == "bump") {
				if (bumped != null) { error(where + ": @bump is written twice", d); }
				if (args.length > 1) { error(where + " takes the bump, or nothing for the canonical one", d); }
				bumped = d;
				continue;
			}
			if (name == "hasOne") {
				if (args.length < 1 || args.length > 2 || args[0].kind !== NodeKind.Identifier) {
					error(where + " takes the name of an account field and an optional error", d);
				}
				const target = args[0].name;
				if (fieldIndex(target) < 0) {
					error(where + ": '" + target + "' is not a field of " + decl.interfaceName, args[0]);
				}
				if (!dataFieldOf(owner, target, args[0])) {
					error(where + ": '" + self + "' must be Owned<T>, Mutable<T> or Delegated<T> " +
						"of a struct with a field '" + target + "'", d);
				}
				const stored = call(bindSym("keyAddressOf")!, [
					member(call(member(member(ident(holder, d), self, d), "data", d), [], d), target, d),
				], d);
				if (args.length == 2) {
					related.push(lazily(call(bindSym("keysEqual")!, [stored, keyOf(args[0])], d), args[1], d));
					continue;
				}
				const failure = whole(ProgramError.constraintHasOne().code as number, d);
				related.push(attempt(call(bindSym("keysMatch")!, [stored, keyOf(args[0]), failure], d), d));
				continue;
			}
			if (name == "constraint") {
				if (args.length < 1 || args.length > 2) {
					error(where + " takes a condition and an optional error", d);
				}
				if (args.length == 2) {
					required.push(lazily(rewrite(args[0]), args[1], d));
					continue;
				}
				const failure = whole(ProgramError.constraintRaw().code as number, d);
				required.push(attempt(call(bindSym("holds")!, [rewrite(args[0]), failure], d), d));
				continue;
			}
			if (name == "address") {
				if (args.length < 1 || args.length > 2) {
					error(where + " takes a key and an optional error", d);
				}
				if (args.length == 2) {
					addressed.push(lazily(call(bindSym("keysEqual")!, [keyOf(ident(self, d)), keyOf(args[0])], d), args[1], d));
					continue;
				}
				const failure = whole(ProgramError.constraintAddress().code as number, d);
				addressed.push(attempt(call(bindSym("keysMatch")!, [keyOf(ident(self, d)), keyOf(args[0]), failure], d), d));
				continue;
			}
			if (name == "associated" || name == "tokenMint" || name == "tokenAuthority") {
				if (!isToken) {
					error(where + ": the field must be External<TokenAccount> or ExternalMutable<TokenAccount>", d);
				}
				if (name == "associated") {
					if (args.length == 3) {
						error(where + ": the token program is the mint's owner, so a third argument " +
							"(associated_token::token_program) is not supported", d);
					}
					if (args.length != 2) { error(where + " takes the mint and the authority", d); }
					associated.push(attempt(call(
						bindSym("associatedMatches")!,
						[keyOf(ident(self, d)), keyOf(args[1]), keyOf(args[0])],
						d,
					), d));
					continue;
				}
				if (args.length != 1) { error(where + " takes one key", d); }
				if (name == "tokenMint") {
					minted.push(attempt(call(bindSym("tokenMintMatches")!, [keyOf(ident(self, d)), keyOf(args[0])], d), d));
				} else {
					authorized.push(attempt(call(bindSym("tokenAuthorityMatches")!, [keyOf(ident(self, d)), keyOf(args[0])], d), d));
				}
				continue;
			}
			error(where + ": accounts<T>() reads @seeds, @bump, @hasOne, @address, @associated, " +
				"@constraint, @tokenMint and @tokenAuthority", d);
		}
		if (bumped != null && seeded == null) {
			error("accounts<" + decl.interfaceName + ">(): @bump on field '" + self +
				"' needs @seeds before it", bumped);
		}
		if (seeded != null) {
			if (bumped == null) {
				error("accounts<" + decl.interfaceName + ">(): @seeds on field '" + self +
					"' needs @bump: write @bump(account.field) for a stored bump or a bare @bump " +
					"for the canonical one", seeded);
			}
			const list: Node[] = [];
			let seed = 0;
			while (seed < seeded.macroArgs.length) {
				list.push(rewrite(seeded.macroArgs[seed]));
				seed = seed + 1;
			}
			const table = call(bindSym("seedTable")!, [{
				kind: NodeKind.ArrayLiteral,
				line: seeded.line,
				column: seeded.column,
				elements: list,
			}], seeded);
			const key = keyOf(ident(self, seeded));
			if (bumped.macroArgs.length == 1) {
				checks.push(attempt(call(
					bindSym("seedsGiven")!,
					[key, table, rewrite(bumped.macroArgs[0])],
					seeded,
				), seeded));
			} else {
				checks.push(attempt(call(bindSym("seedsCanonical")!, [key, table], seeded), seeded));
			}
		}
		const groups: Node[][] = [associated, related, required, addressed, authorized, minted];
		let group = 0;
		while (group < groups.length) {
			let each = 0;
			while (each < groups[group].length) {
				checks.push(groups[group][each]);
				each = each + 1;
			}
			group = group + 1;
		}
		owner = owner + 1;
	}
	const built: Node = {
		kind: NodeKind.ObjectLiteral,
		line: line,
		column: column,
		properties: values,
		keys: decl.interfaceFields,
		keyLocations: [],
	};
	const yes: Node = { kind: NodeKind.BooleanLiteral, line: line, column: column, boolValue: true };
	if (checks.length == 0) {
		return call(bindSym("readArgs")!, [yes, built], shape);
	}
	const statements: Node[] = [{
		kind: NodeKind.VariableDecl,
		line: line,
		column: column,
		declName: holder,
		declType: decl.interfaceName,
		declKind: DeclKind.Const,
		initializer: built,
		nameLocation: { line: line, column: column },
	}];
	let step = 0;
	while (step < checks.length) {
		statements.push(checks[step]);
		step = step + 1;
	}
	statements.push(call(bindSym("readArgs")!, [yes, ident(holder, shape)], shape));
	return { kind: NodeKind.SpliceMany, line: line, column: column, spliceNodes: statements };
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
			" bytes with its discriminator, over the 1024 the std buffers", value);
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

const SEED_LIST_REQUIRED = "seeds must be written as a list at the call: [\"pet\", mint, [bump]]";

const KEY_REQUIRED = "a key is an account or a Pubkey";

macro keyAddressOf(operand: Node): Node {
	const line = operand.line;
	const column = operand.column;
	const written = operand.nodeType;
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
	if (name == "Account" || (name == "Distinct" && inner == "Account") ||
		name == "Program" || name == "Owned" || name == "Mutable" ||
		name == "External" || name == "ExternalMutable" || name == "Delegated") {
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

macro seedTable(list: Node): Node {
	if (list.kind !== NodeKind.ArrayLiteral) {
		error(SEED_LIST_REQUIRED, list);
	}
	const slices: Node[] = [];
	let position = 0;
	while (position < list.elements.length) {
		const element = list.elements[position];
		const line = element.line;
		const column = element.column;
		const written = element.nodeType;
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
			if (name == "Account" || (name == "Distinct" && inner == "Account") ||
				name == "Program" || name == "Owned" || name == "Mutable" ||
				name == "External" || name == "ExternalMutable" || name == "Delegated") {
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
	return {
		kind: NodeKind.CallExpr,
		line: payer.line,
		column: payer.column,
		callee: bindSym("createPdaOf"),
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

export macro signed(call: Node, seeds: Node): Node {
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
	const shape = call.callee.nodeType;
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
			"parameter is `signers: Span<SignerSeeds>` can be signed", call);
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
				const written = seed.nodeType;
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
	position = 0;
	while (position < lists.length) {
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

export macro delegate(accounts: Node, seeds: Node, bump: Node, config: Node): Node {
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
