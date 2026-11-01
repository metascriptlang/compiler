import {
	Node, NodeKind, NodeFlag, Type, TypeKind, TypeFlag, Symbol,
	SymbolKind, SymbolFlag, SourceLocation, ProgramData, ExportDeclData,
	DecoratedDeclData, FunctionDeclData, VariableDeclData, DeclKind,
	InterfaceDeclData, EnumDeclData, ImportDeclData, ExprStmtData,
	ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
} from "../ast/node";
import {
	CheckerContext, hasErrors, isGenericFn, isExtensionRoutine,
	routineKindFlag,
} from "../checker/context";
import {
	lookupSymbol, hasFlag, isTypeSymbol, routineFlagSet, RoutineFlag,
} from "../checker/symbol";
import { isCtorSignature, requiredCtorArgs } from "../checker/ctorRoutine";
import { getDeclName, resolveImportSourcePath } from "../checker/collectPass";
import {
	isMaybeType, unwrapMaybeType, unwrapRefBase, isAwaitable,
	awaitedType, isAffineAwaitable, getMinArity, numberLiteralBase,
	declGenericParams, mappedModifiers, MappedModifier,
	isIterator, getIteratorYieldType,
} from "../checker/types";
import { needsAutoAsync, escapeJSString } from "../codegen/js/emit";
import { jsMethodMemberName } from "../codegen/js/expressions";

export interface DeclarationModule {
	sourcePath: string;
	program: Node;
	ctx: CheckerContext;
}

export interface DeclarationFile {
	sourcePath: string;
	text: string;
}

export interface DeclarationDiagnostic {
	sourcePath: string;
	line: int32;
	column: int32;
	message: string;
}

export interface DeclarationResult {
	files: DeclarationFile[];
	diagnostics: DeclarationDiagnostic[];
}

class DeclarationEntry {
	module: DeclarationModule;
	node: Node;
	sym: Symbol;
	name: string;
}

class DeclarationSelection {
	module: DeclarationModule;
	allExports: boolean;
	names: Set<string>;
	queued: boolean;
}

class DeclarationState {
	selections: DeclarationSelection[];
	selection: DeclarationSelection;
	entries: DeclarationEntry[];
	module: DeclarationModule;
	pending: DeclarationEntry[];
	needed: HashSet<Symbol>;
	imports: string[];
	importSymbols: Symbol[];
	importNames: string[];
	exports: string[];
	diagnostics: DeclarationDiagnostic[];
	mapSpecifier: (fromPath: string, toPath: string) => string;
	location: SourceLocation;
	parameters: Type[];
	visiting: Type[];
}

function unwrapped(node: Node): Node {
	let current = node;
	while (current.kind == NodeKind.ExportDecl ||
		current.kind == NodeKind.DecoratedDecl) {
		current = current.kind == NodeKind.ExportDecl
			? (current.data as ExportDeclData).exportedDecl
			: (current.data as DecoratedDeclData).decoratedNode;
	}
	return current;
}

function quote(text: string): string {
	return "\"" + escapeJSString(text) + "\"";
}

function identifier(text: string): boolean {
	if (text == "") return false;
	for (let i: int32 = 0; i < text.byteLength; i += 1) {
		const c = text.byteAt(i);
		if ((c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
			c == 95 || c == 36 || (i > 0 && c >= 48 && c <= 57)) continue;
		return false;
	}
	return true;
}

function fail(state: DeclarationState, message: string): string {
	state.diagnostics.push({
		sourcePath: state.module.sourcePath,
		line: state.location.line,
		column: state.location.column,
		message: "cannot emit JS declaration: " + message,
	});
	return "";
}

function sameDeclaration(left: Symbol, right: Symbol): boolean {
	if (left == right) return true;
	return left.declNode != null && left.declNode == right.declNode;
}

function entryOf(state: DeclarationState, sym: Symbol): DeclarationEntry | null {
	for (const entry of state.entries) {
		if (sameDeclaration(entry.sym, sym)) return entry;
	}
	return null;
}

function typeEntry(state: DeclarationState, t: Type): DeclarationEntry | null {
	if (t.sym != null) {
		const entry = entryOf(state, t.sym);
		if (entry != null) return entry;
	}
	for (const entry of state.entries) {
		if (isTypeSymbol(entry.sym) &&
			(entry.sym.symbolType == t ||
				unwrapRefBase(entry.sym.symbolType) == t)) return entry;
	}
	return null;
}

function requireEntry(state: DeclarationState, entry: DeclarationEntry): void {
	if (state.needed.has(entry.sym)) return;
	state.needed.add(entry.sym);
	state.pending.push(entry);
}

function requestModule(
	state: DeclarationState,
	path: string,
	name: string,
	allExports: boolean = false,
): void {
	for (const selection of state.selections) {
		if (selection.module.sourcePath != path) continue;
		if (allExports && !selection.allExports) {
			selection.allExports = true;
			selection.queued = true;
		} else if (!selection.allExports && !selection.names.has(name)) {
			selection.names.add(name);
			selection.queued = true;
		}
		return;
	}
	fail(state, "required source module '" + path + "' was not collected before lowering");
}

function publicNames(module: DeclarationModule, sym: Symbol): string[] {
	for (const exported of module.ctx.interf) {
		if (sameDeclaration(exported, sym)) {
			return module.ctx.interfNames.get(exported) ?? [exported.name];
		}
	}
	return [];
}

function moduleSpecifier(state: DeclarationState, target: string): string {
	const mapped = state.mapSpecifier(state.module.sourcePath, target);
	if (mapped == "") fail(state, "no module specifier for '" + target + "'");
	return quote(mapped);
}

function referenceEntry(
	state: DeclarationState,
	entry: DeclarationEntry,
): string {
	if (entry.module.sourcePath == state.module.sourcePath) {
		requireEntry(state, entry);
		return entry.name;
	}
	for (let i: int32 = 0; i < state.importSymbols.length; i += 1) {
		if (sameDeclaration(state.importSymbols[i], entry.sym)) {
			return state.importNames[i];
		}
	}
	const names = publicNames(entry.module, entry.sym);
	if (names.length == 0) {
		return fail(state, "type '" + entry.name + "' from '" +
			entry.module.sourcePath + "' is not exported; name a public type");
	}
	let local = "__declarationType" + state.importNames.length.toString();
	while (lookupSymbol(state.module.ctx.table, local) != null) local += "_";
	const name = names[0];
	requestModule(state, entry.module.sourcePath, name);
	state.importSymbols.push(entry.sym);
	state.importNames.push(local);
	state.imports.push((entry.node.kind == NodeKind.ClassDecl
		? "import { " : "import type { ") + name + " as " + local +
		" } from " + moduleSpecifier(state, entry.module.sourcePath) + ";\n");
	return local;
}

function joinedTypes(state: DeclarationState, types: Type[], sep: string): string {
	const texts: string[] = [];
	for (const type of types) texts.push(typeSyntax(state, type));
	return texts.join(sep);
}

function primitive(t: Type): string {
	return match (t.kind) {
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Never => "never",
		TypeKind.Unknown => "unknown",
		TypeKind.NonPrimitive => "object",
		TypeKind.Int64 | TypeKind.Uint64 | TypeKind.BigInt => "bigint",
		TypeKind.Number | TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 |
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Float32 |
		TypeKind.Float64 | TypeKind.Char => "number",
		_ => "",
	};
}

function fieldVisibility(t: Type, name: string): string {
	const node = t.sym == null ? null : t.sym.declNode;
	if (node == null || (node.kind != NodeKind.InterfaceDecl &&
		node.kind != NodeKind.StructDecl)) return "";
	const data = node.data as InterfaceDeclData;
	const index = data.interfaceFields.indexOf(name);
	if (index >= 0 && index < data.interfaceFieldVisibility.length) {
		return data.interfaceFieldVisibility[index];
	}
	if (node.baseExprs != null) {
		for (const base of node.baseExprs) {
			if (base.nodeType == null) continue;
			const visibility = fieldVisibility(unwrapRefBase(base.nodeType), name);
			if (visibility != "") return visibility;
		}
	}
	return "";
}

function objectSyntax(state: DeclarationState, t: Type): string {
	const fields: string[] = [];
	if (t.typeNames.length != t.typeChildren.length) {
		return fail(state, "object type has incomplete checked fields");
	}
	for (let i: int32 = 0; i < t.typeNames.length; i += 1) {
		const name = t.typeNames[i];
		const optional = t.optionalFields != null && t.optionalFields.includes(name);
		const visibility = fieldVisibility(t, name);
		if (visibility.contains("private") || visibility.contains("protected")) {
			return fail(state, "non-public field '" + name + "' has no verified TS identity");
		}
		fields.push((visibility.contains("readonly") ? "readonly " : "") +
			quote(name) + (optional ? "?" : "") + ": " +
			typeSyntax(state, t.typeChildren[i]) + ";");
	}
	return "{ " + fields.join(" ") + " }";
}

function parameterSyntax(
	state: DeclarationState, t: Type, start: int32 = 0,
): string {
	const parameters: string[] = [];
	const minimum = getMinArity(t);
	for (let i: int32 = start; i < t.typeChildren.length; i += 1) {
		let child = t.typeChildren[i];
		const rest = child.kind == TypeKind.Varargs;
		if (rest) {
			if (i != t.typeChildren.length - 1 || child.typeChildren.length != 1) {
				return fail(state, "rest parameter has no final checked array type");
			}
			child = child.typeChildren[0];
		}
		let name = i < t.typeNames.length ? t.typeNames[i] : "";
		if (!identifier(name) || name == "this") name = "arg" + i.toString();
		parameters.push((rest ? "..." : "") + name +
			(!rest && i >= minimum ? "?" : "") + ": " + typeSyntax(state, child));
	}
	return parameters.join(", ");
}

function tupleSyntax(state: DeclarationState, t: Type): string {
	const children: string[] = [];
	for (let i: int32 = 0; i < t.typeChildren.length; i += 1) {
		const child = t.typeChildren[i];
		if (child.kind == TypeKind.Varargs && child.typeChildren.length == 1) {
			children.push("..." + typeSyntax(state, child.typeChildren[0]));
		} else {
			children.push(typeSyntax(state, child) +
				(i >= getMinArity(t) ? "?" : ""));
		}
	}
	return "[" + children.join(", ") + "]";
}

function mappedSyntax(state: DeclarationState, t: Type): string {
	if (t.typeReturn == null || t.typeChildren.length < 2) {
		return fail(state, "mapped type has no checked binder or template");
	}
	const param = t.typeReturn;
	if (!identifier(param.typeName)) return fail(state, "invalid mapped binder");
	state.parameters.push(param);
	const mods = mappedModifiers(t);
	const readonly = mods.has(MappedModifier.IncludeReadonly) ? "+readonly "
		: mods.has(MappedModifier.ExcludeReadonly) ? "-readonly " : "";
	const optional = mods.has(MappedModifier.IncludeOptional) ? "+?"
		: mods.has(MappedModifier.ExcludeOptional) ? "-?" : "";
	const key = typeSyntax(state, t.typeChildren[0]);
	const rename = t.typeChildren.length > 2
		? " as " + typeSyntax(state, t.typeChildren[2]) : "";
	const value = typeSyntax(state, t.typeChildren[1]);
	state.parameters.pop();
	return "{ " + readonly + "[" + param.typeName + " in " + key + rename +
		"]" + optional + ": " + value + " }";
}

function typeSyntax(
	state: DeclarationState,
	t: Type | null,
	expanding: DeclarationEntry | null = null,
): string {
	if (t == null) return fail(state, "missing checked public type");
	const alias = typeEntry(state, t);
	if (alias != null && alias != expanding &&
		alias.sym.symbolKind == SymbolKind.TypeAlias &&
		t.kind != TypeKind.GenericParam) return referenceEntry(state, alias);
	const atomic = primitive(t);
	if (atomic != "") return atomic;
	if (t.kind == TypeKind.GenericParam) {
		for (const param of state.parameters) {
			if (param == t || (param.sym != null && t.sym != null &&
				param.sym == t.sym)) return param.typeName;
		}
		return fail(state, "unbound type parameter '" + t.typeName + "'");
	}
	if (t.kind == TypeKind.EnumLiteral && t.typeReturn != null) {
		const entry = typeEntry(state, t.typeReturn);
		const member = t.typeNames.length == 1 ? t.typeNames[0] : "";
		if (entry == null || !identifier(member)) {
			return fail(state, "enum literal has no accessible checked member");
		}
		return referenceEntry(state, entry) + "." + member;
	}
	if (t.kind == TypeKind.StringLiteral) return quote(t.typeName);
	if (t.kind == TypeKind.BooleanLiteral) return t.typeName;
	if (t.kind == TypeKind.NumberLiteral) {
		const base = numberLiteralBase(t);
		return t.typeName + (primitive(base) == "bigint" ? "n" : "");
	}
	if (isMaybeType(t)) {
		return "(" + typeSyntax(state, unwrapMaybeType(t)) + " | null)";
	}
	if (isAwaitable(t)) {
		if (isAffineAwaitable(t)) {
			return fail(state, "affine awaitable ownership cannot cross the JS API");
		}
		return "Promise<" + typeSyntax(state, awaitedType(t)) + ">";
	}
	if (t.kind == TypeKind.Ref) {
		if (t.typeFlags.has(TypeFlag.IsAtomic) ||
			t.typeFlags.has(TypeFlag.IsOwned) ||
			t.typeFlags.has(TypeFlag.IsLocked)) {
			return fail(state, "owned or synchronized reference has no public JS type");
		}
		const inner = t.typeReturn;
		if (inner == null || (inner.kind != TypeKind.Struct &&
			inner.kind != TypeKind.Array && inner.kind != TypeKind.Tuple &&
			inner.kind != TypeKind.GenericInstance && inner.kind != TypeKind.Union)) {
			return fail(state, "explicit reference has no public JS representation");
		}
		const syntax = typeSyntax(state, inner, expanding);
		return t.typeFlags.has(TypeFlag.IsReadonly)
			? "Readonly<" + syntax + ">" : syntax;
	}
	if (t.kind == TypeKind.GenericInstance) {
		const base = t.typeExtra == null ? null : unwrapRefBase(t.typeExtra);
		const entry = base == null ? null : typeEntry(state, base);
		if (entry != null) {
			return referenceEntry(state, entry) + "<" +
				joinedTypes(state, t.typeChildren, ", ") + ">";
		}
		if (isIterator(t)) {
			return "IterableIterator<" +
				typeSyntax(state, getIteratorYieldType(t)) + ">";
		}
		return fail(state, "generic type '" + t.typeName +
			"' has no accessible checked declaration");
	}
	const named = typeEntry(state, t);
	if (named != null && named != expanding) return referenceEntry(state, named);
	if (state.visiting.includes(t)) {
		return fail(state, "anonymous recursive type needs a named public annotation");
	}
	state.visiting.push(t);
	const syntax = structuralSyntax(state, t);
	state.visiting.pop();
	return syntax;
}

function structuralSyntax(state: DeclarationState, t: Type): string {
	match (t.kind) {
		TypeKind.Alias => { return typeSyntax(state, t.typeReturn); },
		TypeKind.Array => {
			return (t.typeFlags.has(TypeFlag.IsReadonly) ? "ReadonlyArray<" : "Array<") +
				typeSyntax(state, t.typeReturn) + ">";
		},
		TypeKind.Tuple => { return tupleSyntax(state, t); },
		TypeKind.Struct => { return objectSyntax(state, t); },
		TypeKind.Union => {
			if (t.typeChildren.length == 0) return fail(state, "empty checked union");
			return "(" + joinedTypes(state, t.typeChildren, " | ") + ")";
		},
		TypeKind.Function => {
			return "((" + parameterSyntax(state, t) + ") => " +
				typeSyntax(state, t.typeReturn) + ")";
		},
		TypeKind.KeyOf => {
			if (t.typeChildren.length == 1) {
				return "keyof " + typeSyntax(state, t.typeChildren[0]);
			}
		},
		TypeKind.IndexedAccess => {
			if (t.typeChildren.length == 2) {
				return typeSyntax(state, t.typeChildren[0]) + "[" +
					typeSyntax(state, t.typeChildren[1]) + "]";
			}
		},
		TypeKind.Conditional => {
			if (t.typeChildren.length == 4 && t.typeReturn == null) {
				return "(" + typeSyntax(state, t.typeChildren[0]) + " extends " +
					typeSyntax(state, t.typeChildren[1]) + " ? " +
					typeSyntax(state, t.typeChildren[2]) + " : " +
					typeSyntax(state, t.typeChildren[3]) + ")";
			}
		},
		TypeKind.Mapped => { return mappedSyntax(state, t); },
		_ => {},
	}
	return fail(state, "unsupported public type kind " + t.kind.toString() +
		(t.typeName == "" ? "" : " ('" + t.typeName + "')"));
}

function genericParameters(state: DeclarationState, entry: DeclarationEntry): string {
	const declared = declGenericParams(entry.node);
	const parameters = entry.sym.typeParams;
	if (declared != "" && parameters.length == 0) {
		return fail(state, "type '" + entry.name + "' lost its checked type parameters");
	}
	const texts: string[] = [];
	for (const param of parameters) {
		if (!identifier(param.typeName)) {
			return fail(state, "type parameter has no representable checked name");
		}
		state.parameters.push(param);
	}
	const defaults = entry.node.genericDefaults;
	for (let i: int32 = 0; i < parameters.length; i += 1) {
		const param = parameters[i];
		const annotation = defaults != null && i < defaults.length
			? defaults[i] : null;
		if (annotation != null && param.typeParamDefault == null) {
			state.location = annotation.location;
			return fail(state, "type parameter '" + param.typeName +
				"' lost its checked default");
		}
		texts.push(param.typeName + (param.typeExtra == null ? "" :
			" extends " + typeSyntax(state, param.typeExtra)) +
			(param.typeParamDefault == null ? "" :
				" = " + typeSyntax(state, param.typeParamDefault)));
	}
	return texts.length == 0 ? "" : "<" + texts.join(", ") + ">";
}

function functionDeclaration(state: DeclarationState, entry: DeclarationEntry): string {
	const sym = entry.sym;
	const data = entry.node.data as FunctionDeclData;
	if (isGenericFn(data.fnFlags) || sym.typeParams.length > 0) {
		return fail(state, "runtime generic '" + entry.name +
			"' is specialized, not a host-callable JS value; export a concrete wrapper");
	}
	if (isExtensionRoutine(data.fnFlags)) {
		return fail(state, "extension routine '" + entry.name +
			"' has no source-named JS binding");
	}
	let bodies: int32 = hasFlag(sym, SymbolFlag.OverloadSig) ? 0 : 1;
	for (const overload of sym.overloads) {
		if (!hasFlag(overload, SymbolFlag.OverloadSig)) bodies += 1;
	}
	if (bodies != 1 || sym.overloads.length > 0 ||
		hasFlag(sym, SymbolFlag.OverloadSig)) {
		return fail(state, "overloaded runtime binding '" + entry.name +
			"' has no verified single source-named JS export");
	}
	const type = sym.symbolType;
	if (type == null || type.kind != TypeKind.Function) {
		return fail(state, "routine '" + entry.name + "' has no checked signature");
	}
	if (!requiredParameters(state, type, data.fnDefaults, 0, entry.name)) return "";
	if (!callbackAbiSupported(state, type, [], entry.name)) return "";
	const params = parameterSyntax(state, type);
	let returns = typeSyntax(state, type.typeReturn);
	const kind = routineKindFlag(data.fnFlags);
	const autoAsync = needsAutoAsync(data.fnFlags, data.fnBody);
	if (kind == "generator" || kind == "async_generator") {
		if (!isIterator(type.typeReturn)) {
			return fail(state, "generator '" + entry.name + "' has no checked yield type");
		}
		const yieldType = typeSyntax(state, getIteratorYieldType(type.typeReturn!));
		returns = (kind == "async_generator" || autoAsync
			? "AsyncGenerator<" : "Generator<") + yieldType + ", void, unknown>";
	} else if ((kind == "async" || autoAsync) && !isAwaitable(type.typeReturn)) {
		returns = "Promise<" + returns + ">";
	}
	return "declare function " + entry.name + "(" + params + "): " + returns + ";\n";
}

function requiredParameters(
	state: DeclarationState, type: Type, defaults: Node[], start: int32,
	apiName: string,
): boolean {
	for (let i = start; i < type.typeChildren.length; i += 1) {
		const name = i < type.typeNames.length ? type.typeNames[i] : i.toString();
		if (type.typeChildren[i].kind == TypeKind.Varargs) {
			fail(state, "public callable '" + apiName + "' rest parameter '" +
				name + "' needs verified JS host spread ABI; pending host adaptation");
			return false;
		}
		if ((i < defaults.length && defaults[i] != null) || i >= getMinArity(type)) {
			fail(state, "public callable '" + apiName + "' optional/default parameter '" +
				name + "' needs verified JS host omitted-argument ABI; pending host adaptation");
			return false;
		}
	}
	return true;
}

function callbackAbiSupported(
	state: DeclarationState, type: Type | null, seen: Type[],
	apiName: string,
): boolean {
	if (type == null || seen.includes(type)) return true;
	seen.push(type);
	const entry = typeEntry(state, type);
	if (entry != null && entry.node.kind == NodeKind.ClassDecl) return true;
	if (type.kind == TypeKind.Function) {
		for (let i: int32 = 0; i < type.typeChildren.length; i += 1) {
			if (i < getMinArity(type) &&
				type.typeChildren[i].kind != TypeKind.Varargs) continue;
			const name = i < type.typeNames.length ? type.typeNames[i] : i.toString();
			fail(state, "public API '" + apiName + "' parameter '" + name +
				"': unsupported raw JS callback calling convention; " +
				"optional/default/rest callback parameters need pending host adaptation");
			return false;
		}
	}
	if (entry != null && entry.sym.symbolKind == SymbolKind.TypeAlias &&
		!callbackAbiSupported(state, entry.sym.symbolType, seen, apiName)) return false;
	for (const child of type.typeChildren) {
		if (!callbackAbiSupported(state, child, seen, apiName)) return false;
	}
	return callbackAbiSupported(state, type.typeReturn, seen, apiName) &&
		callbackAbiSupported(state, type.typeExtra, seen, apiName);
}

function classDeclaration(state: DeclarationState, entry: DeclarationEntry): string {
	if (declGenericParams(entry.node) != "" || entry.sym.typeParams.length > 0) {
		return fail(state, "generic class '" + entry.name +
			"' has no universal host-callable JS constructor");
	}
	if (hasFlag(entry.sym, SymbolFlag.InheritsConstructor)) {
		return fail(state, "class '" + entry.name +
			"' inherited constructor needs verified JS host construction");
	}
	const data = entry.node.data as ClassDeclData;
	const type = unwrapRefBase(entry.sym.symbolType);
	if (type.kind != TypeKind.Struct) return fail(state, "class has no checked shape");
	let heritage = "";
	if (data.classExtends != "") {
		const parent = type.typeExtra == null ? null :
			typeEntry(state, unwrapRefBase(type.typeExtra));
		if (parent == null || parent.node.kind != NodeKind.ClassDecl) {
			return fail(state, "class '" + entry.name + "' has no accessible nongeneric base");
		}
		heritage = " extends " + referenceEntry(state, parent);
	}
	const members: string[] = ["#private;"];
	let constructors: int32 = 0;
	for (const raw of data.classBody) {
		const member = unwrapped(raw);
		state.location = member.location;
		if (member.kind == NodeKind.PropertyDecl) {
			const field = member.data as PropertyDeclData;
			if (field.propIsStatic || member.flags.has(NodeFlag.AutoAccessor)) {
				return fail(state, "class " + (field.propIsStatic ? "static" : "accessor") +
					" field '" + field.propName + "' has no verified JS host representation");
			}
			if (field.propVisibility != "private" &&
				!callbackAbiSupported(state, member.nodeType, [],
					entry.name + "." + field.propName)) return "";
			members.push((field.propVisibility == "" ? "" : field.propVisibility + " ") +
				(field.propIsReadonly ? "readonly " : "") + quote(field.propName) +
				(member.flags.has(NodeFlag.Optional) ? "?" : "") + ": " +
				typeSyntax(state, member.nodeType) + ";");
		} else if (member.kind == NodeKind.ConstructorDecl) {
			const ctor = member.data as ConstructorDeclData;
			if (isCtorSignature(member)) {
				return fail(state, "class '" + entry.name +
					"' constructor overload needs a verified single JS runtime constructor");
			}
			constructors += 1;
			const signature = member.nodeType;
			if (signature == null || signature.kind != TypeKind.Function) {
				return fail(state, "class constructor has no checked user signature");
			}
			if (!requiredParameters(state, signature, ctor.ctorDefaults, 0,
				entry.name + ".constructor")) return "";
			if (ctor.ctorVisibility != "private" &&
				!callbackAbiSupported(state, signature, [], entry.name)) return "";
			if (requiredCtorArgs(signature.typeChildren, ctor.ctorDefaults) !=
				signature.typeChildren.length) return fail(state, "class constructor arity is unresolved");
			members.push((ctor.ctorVisibility == "" ? "" : ctor.ctorVisibility + " ") +
				"constructor(" + parameterSyntax(state, signature) + ");");
		} else if (member.kind == NodeKind.MethodDecl) {
			const method = member.data as MethodDeclData;
			if (method.methodVisibility == "private") {
				members.push("private " + quote(method.methodName) + ";");
				continue;
			}
			const sym = member.resolvedSym;
			if (method.methodIsStatic || member.flags.has(NodeFlag.Accessor) ||
				member.flags.has(NodeFlag.Abstract) ||
				isGenericFn(method.methodFlags) ||
				routineFlagSet(method.methodFlags).has(RoutineFlag.Extern) ||
				routineFlagSet(method.methodFlags).has(RoutineFlag.Overload) ||
				sym == null || sym.overloads.length > 0 ||
				jsMethodMemberName(method.methodName, sym) != method.methodName) {
				const reason = method.methodIsStatic ? "static"
					: member.flags.has(NodeFlag.Accessor) ? "accessor"
					: member.flags.has(NodeFlag.Abstract) ? "abstract"
					: isGenericFn(method.methodFlags) ? "generic"
					: routineFlagSet(method.methodFlags).has(RoutineFlag.Extern) ? "extern"
					: "overloaded or renamed";
				return fail(state, "class " + reason + " method '" + method.methodName +
					"' has no verified ordinary source-named JS prototype binding");
			}
			const signature = sym.symbolType;
			if (signature == null || signature.kind != TypeKind.Function ||
				signature.typeNames.length == 0 || signature.typeNames[0] != "this") {
				return fail(state, "class method has no checked receiver signature");
			}
			if (!requiredParameters(state, signature, method.methodDefaults, 1,
				entry.name + "." + method.methodName)) return "";
			if (!callbackAbiSupported(state, signature, [], entry.name)) return "";
			let returns = typeSyntax(state, signature.typeReturn);
			const kind = routineKindFlag(method.methodFlags);
			const autoAsync = needsAutoAsync(method.methodFlags, method.methodBody);
			if (kind == "generator" || kind == "async_generator") {
				if (!isIterator(signature.typeReturn)) return fail(state, "class generator has no checked yield type");
				returns = (kind == "async_generator" || autoAsync ? "AsyncGenerator<" :
					"Generator<") + typeSyntax(state, getIteratorYieldType(signature.typeReturn!)) +
					", void, unknown>";
			} else if ((kind == "async" || autoAsync) && !isAwaitable(signature.typeReturn)) {
				returns = "Promise<" + returns + ">";
			}
			members.push((method.methodVisibility == "" ? "" : method.methodVisibility + " ") +
				quote(method.methodName) + "(" + parameterSyntax(state, signature, 1) +
				"): " + returns + ";");
		} else {
			return fail(state, "class '" + entry.name + "' contains an unrepresented member");
		}
	}
	if (constructors != 1) return fail(state, "class '" + entry.name +
		"' needs one written constructor for verified JS host construction");
	return "declare " + (entry.node.flags.has(NodeFlag.Abstract) ? "abstract " : "") +
		"class " + entry.name + heritage + " {\n\t" + members.join("\n\t") + "\n}\n";
}

function emitEntry(state: DeclarationState, entry: DeclarationEntry): string {
	state.location = entry.node.location;
	state.parameters = [];
	const sym = entry.sym;
	if (!identifier(entry.name)) return fail(state, "invalid declaration name '" + entry.name + "'");
	if (sym.nativeName != "" || hasFlag(sym, SymbolFlag.ImportC) ||
		hasFlag(sym, SymbolFlag.CompileTime) || entry.node.kind == NodeKind.ExternDecl ||
		entry.node.flags.has(NodeFlag.ExternC)) {
		return fail(state, "native or compile-time declaration '" + entry.name +
			"' has no verified public JS representation");
	}
	match (entry.node.kind) {
		NodeKind.FunctionDecl => { return functionDeclaration(state, entry); },
		NodeKind.ClassDecl => { return classDeclaration(state, entry); },
		NodeKind.VariableDecl => {
			const data = entry.node.data as VariableDeclData;
			if (!callbackAbiSupported(state, sym.symbolType, [], entry.name)) return "";
			return "declare " + (data.declKind == DeclKind.Const ? "const " : "let ") +
				entry.name + ": " + typeSyntax(state, sym.symbolType) + ";\n";
		},
		NodeKind.TypeAliasDecl => {
			const params = genericParameters(state, entry);
			let type = sym.symbolType;
			if (type.kind == TypeKind.Alias) type = type.typeReturn!;
			if (type == null) return fail(state, "alias '" + entry.name + "' is unresolved");
			return "type " + entry.name + params + " = " +
				typeSyntax(state, type, entry) + ";\n";
		},
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			const data = entry.node.data as InterfaceDeclData;
			for (const visibility of data.interfaceFieldVisibility) {
				if (visibility.contains("private") || visibility.contains("protected")) {
					return fail(state, "non-public identity of '" + entry.name +
						"' has no verified TS representation");
				}
			}
			const params = genericParameters(state, entry);
			const type = unwrapRefBase(sym.symbolType);
			if (type.kind != TypeKind.Struct) {
				return fail(state, "object declaration '" + entry.name + "' has no checked shape");
			}
			return "interface " + entry.name + params + " " + objectSyntax(state, type) + "\n";
		},
		NodeKind.EnumDecl => {
			const data = entry.node.data as EnumDeclData;
			const members: string[] = [];
			for (let i: int32 = 0; i < data.enumMembers.length; i += 1) {
				if (i >= data.enumValues.length) return fail(state, "enum has unresolved member values");
				members.push(quote(data.enumMembers[i]) + " = " + data.enumValues[i].toString());
			}
			return "declare enum " + entry.name + " { " + members.join(", ") + " }\n";
		},
		_ => {
			return fail(state, "declaration '" + entry.name +
				"' has no traced JS class, member, or runtime representation");
		},
	}
}

function exportedImport(state: DeclarationState, node: Node): void {
	const data = node.data as ImportDeclData;
	const path = resolveImportSourcePath(state.module.ctx, data.importSource);
	if (path == "") {
		fail(state, "unresolved re-export from '" + data.importSource + "'");
		return;
	}
	const typeOnly = node.flags.has(NodeFlag.TypeModifier);
	let clause = "";
	if (data.importNames.length == 1 && data.importNames[0] == "*") {
		requestModule(state, path, "", true);
		clause = "*";
		if (data.importAliases.length > 0 && data.importAliases[0] != "*" &&
			data.importAliases[0] != "") clause += " as " + data.importAliases[0];
	} else {
		const names: string[] = [];
		for (let i: int32 = 0; i < data.importNames.length; i += 1) {
			const name = data.importNames[i];
			const alias = i < data.importAliases.length ? data.importAliases[i] : name;
			if (!state.selection.allExports && !state.selection.names.has(alias)) continue;
			requestModule(state, path, name);
			names.push((!typeOnly && data.importTypeNames.includes(name) ? "type " : "") +
				name + (alias == name ? "" : " as " + alias));
		}
		if (names.length == 0) return;
		clause = "{ " + names.join(", ") + " }";
	}
	state.exports.push("export " + (typeOnly ? "type " : "") + clause +
		" from " + moduleSpecifier(state, path) + ";\n");
}

function seedExports(state: DeclarationState): void {
	const reexported = new Set<string>();
	const defaultFunctions = new Set<string>();
	for (const stmt of (state.module.program.data as ProgramData).programStmts) {
		let node = stmt;
		if (node.kind == NodeKind.DecoratedDecl) node = (node.data as DecoratedDeclData).decoratedNode;
		if (node.kind != NodeKind.ExportDecl) continue;
		const inner = (node.data as ExportDeclData).exportedDecl;
		if (node.flags.has(NodeFlag.ExportDefault)) {
			if (inner.kind == NodeKind.FunctionDecl) {
				defaultFunctions.add((inner.data as FunctionDeclData).fnName);
			} else if (state.selection.allExports || state.selection.names.has("default")) {
				state.location = inner.location;
				if (inner.kind != NodeKind.ExprStmt) {
					fail(state, "default export has no checked expression or function");
				} else {
					let local = "__declarationDefault";
					while (lookupSymbol(state.module.ctx.table, local) != null) local += "_";
					const expr = (inner.data as ExprStmtData).expr;
					if (!callbackAbiSupported(state, expr.nodeType, [], "default")) continue;
					state.exports.push("declare const " + local + ": " +
						typeSyntax(state, expr.nodeType) + ";\nexport default " + local + ";\n");
				}
			}
		}
		if (inner.kind != NodeKind.ImportDecl) continue;
		state.location = inner.location;
		exportedImport(state, inner);
		const imp = inner.data as ImportDeclData;
		for (const alias of imp.importAliases) reexported.add(alias);
	}
	const bound = new Set<string>();
	for (const sym of state.module.ctx.interf) {
		const entry = entryOf(state, sym);
		const names = state.module.ctx.interfNames.get(sym) ?? [sym.name];
		for (const exportedName of names) {
			const name = defaultFunctions.has(exportedName) ? "default" : exportedName;
			if (!state.selection.allExports && !state.selection.names.has(name)) continue;
			if (bound.has(name) || reexported.has(name)) continue;
			bound.add(name);
			state.location = sym.location;
			if (entry == null) {
				if (sym.declNode != null &&
					unwrapped(sym.declNode).kind == NodeKind.MethodDecl) continue;
				fail(state, "export '" + name + "' has no checked source declaration");
				continue;
			}
			if (entry.module.sourcePath != state.module.sourcePath) continue;
			requireEntry(state, entry);
			const typeOnly = sym.symbolKind == SymbolKind.TypeAlias ||
				sym.symbolKind == SymbolKind.Interface || sym.symbolKind == SymbolKind.Struct;
			state.exports.push("export " + (typeOnly ? "type " : "") + "{ " + entry.name +
				(name == entry.name ? "" : " as " + name) + " };\n");
		}
	}
}

export function emitDeclarations(
	modules: DeclarationModule[],
	mapSpecifier: (fromPath: string, toPath: string) => string,
	requestedSourcePaths: string[],
): DeclarationResult {
	const diagnostics: DeclarationDiagnostic[] = [];
	const files: DeclarationFile[] = [];
	const entries: DeclarationEntry[] = [];
	for (const module of modules) {
		if (hasErrors(module.ctx)) {
			diagnostics.push({ sourcePath: module.sourcePath, line: 1, column: 0,
				message: "cannot emit declarations from a module with checker errors" });
		}
		for (const stmt of (module.program.data as ProgramData).programStmts) {
			const node = unwrapped(stmt);
			const name = getDeclName(node);
			if (name == "") continue;
			const sym = node.resolvedSym ?? lookupSymbol(module.ctx.table, name);
			if (sym != null) entries.push({ module, node, sym, name });
		}
	}
	if (diagnostics.length > 0) return { files: [], diagnostics };
	const selections: DeclarationSelection[] = [];
	for (const module of modules) {
		const requested = requestedSourcePaths.includes(module.sourcePath);
		selections.push({ module, allExports: requested,
			names: new Set<string>(), queued: requested });
	}
	for (const path of requestedSourcePaths) {
		let found = false;
		for (const module of modules) { if (module.sourcePath == path) found = true; }
		if (!found) diagnostics.push({ sourcePath: path, line: 1, column: 0,
			message: "requested declaration source was not collected before lowering" });
	}
	let pending = true;
	while (pending) {
		pending = false;
		for (const selection of selections) {
			if (!selection.queued) continue;
			selection.queued = false;
			pending = true;
			const module = selection.module;
			const state: DeclarationState = {
				selections, selection, entries, module, pending: [],
				needed: new HashSet<Symbol>(), imports: [], importSymbols: [],
				importNames: [], exports: [], diagnostics, mapSpecifier,
				location: module.program.location, parameters: [], visiting: [],
			};
			seedExports(state);
			const bodies: string[] = [];
			for (let i: int32 = 0; i < state.pending.length; i += 1) {
				bodies.push(emitEntry(state, state.pending[i]));
			}
			const text = state.imports.join("") + bodies.join("") +
				state.exports.join("") + "export {};\n";
			let previous: DeclarationFile | null = null;
			for (const file of files) {
				if (file.sourcePath == module.sourcePath) previous = file;
			}
			if (previous != null) previous.text = text;
			else files.push({ sourcePath: module.sourcePath, text });
		}
	}
	return { files: diagnostics.length == 0 ? files : [], diagnostics };
}
