// Method → Function Lowering — convert class methods into top-level functions.
//
// Why: at the C/Raiser ABI level, a class method is just a function that takes
// the receiver as its first param. The user-facing call site has already been
// rewritten by `extensionMethodLower` (`b.count(items)` → `count(b, items)`),
// so by the time we run, no consumer needs the method to live on the class
// any more. Lifting MethodDecl → FunctionDecl at module top-level gives every
// downstream pass (lambdaLifting, dce, codegen) a single uniform shape to
// reason about — no parallel `genMethodAsFunction` path that drifts from
// `genFunctionDecl` (Bug 9 was exactly that drift).
//
// Ref parity: the reference synthesises dispatcher procs pre-codegen, then
// dispatches `skProc | skFunc | skMethod | …` through the same `genProc`.
// We do the equivalent — produce FunctionDecl, codegen only sees FunctionDecl.
//
// Scope (this pass): instance + static methods AND constructors. The
// constructor body lifts to a top-level `<Class>_init(this, ...)` function;
// no `_new` wrapper is synthesised — the C codegen NewExpr handler inlines
// `alloc + _init(this, args)` at the call site (matches the inline pattern
// already used for class-without-ctor and matches Nim's `genObjConstr`).
//
// JS backend: NOT applied. JS keeps `class Foo { ... }` native because its
// class semantics map 1:1 with what we want at the source level (single
// dispatch on `this`, prototype chain). The transform is wired in the
// `!jsBackend` branch of the pipeline.

import { Node, NodeKind, NodeData, createNodeAt, ProgramData, ClassDeclData, MethodDeclData, ConstructorDeclData, DecoratedDeclData, ExportDeclData, ActorDeclData, SymbolKind } from "../../ast/node";
import { TransformContext } from "../context";
import { makeSymbol, setFlag, SymbolFlag } from "../../checker/symbol";
import { createFunction, voidType, unknownType } from "../../checker/types";
import { getGenericDecl } from "../../parser/context";

// ===== Synthesize FunctionDecl from MethodDecl =====
//
// `collectClassMethod` already prepended "this" to methodParams + methodParamTypes
// for non-static methods, and aligned methodDefaults the same way (Bug 8 fix).
// The method's resolvedSym name is `<className>_<methodName>` with all
// mutatedParams / defaultParams / nativeName / declNode / state already wired —
// re-use it as-is on the synthesized FunctionDecl so codegen, default-fill,
// and cross-module lookup all behave identically.
function methodToFunctionDecl(methodNode: Node): Node {
	const md = methodNode.data as MethodDeclData;
	// Method's resolvedSym already has the mangled name `<class>_<method>`.
	// Caller side (after extensionMethodLower) issues `<class>_<method>(receiver, args)`;
	// FunctionDecl mangling reads sym.name through resolvedSym, so using sym.name
	// keeps the call/decl pair in sync.
	const fnName = methodNode.resolvedSym !== null && methodNode.resolvedSym.name !== ""
		? methodNode.resolvedSym.name
		: md.methodName;
	const fnData: NodeData = {
		fnName: fnName,
		params: md.methodParams,
		fnParamTypes: md.methodParamTypes,
		fnBody: md.methodBody,
		fnFlags: md.methodFlags,
		fnReturnType: md.methodReturnType,
		fnDefaults: md.methodDefaults !== null ? md.methodDefaults : [],
		nativeName: md.nativeName,
		nameLocation: md.nameLocation,
	};
	const fnNode = createNodeAt(NodeKind.FunctionDecl, fnData, methodNode.location);
	// Carry over checker-stamped state so downstream passes see a fully-shaped
	// FunctionDecl (typed signature, indirectParams analysis, defaultParams).
	fnNode.nodeType = methodNode.nodeType;
	fnNode.resolvedSym = methodNode.resolvedSym;
	fnNode.flags = methodNode.flags;
	fnNode.paramLocations = methodNode.paramLocations;
	fnNode.typeExpr = methodNode.typeExpr;
	fnNode.typeExprs = methodNode.typeExprs;
	// Update sym.declNode so anyone resolving the symbol sees the FunctionDecl
	// rather than the now-orphaned MethodDecl (matters for default-fill, LSP
	// hover-on-decl, and any later transform that walks `sym.declNode`).
	if (fnNode.resolvedSym !== null) {
		fnNode.resolvedSym.declNode = fnNode;
	}
	return fnNode;
}

// Synthesize a `<Class>_init(this, ...)` FunctionDecl from a ConstructorDecl.
// The ctor body becomes the function body; `this` is prepended as the first
// parameter so the function shape mirrors any other instance method.
//
// We synthesise a fresh Symbol (kind=Function, Exported flag) because the
// ConstructorDecl never had its own resolvedSym — its types/defaults were
// stamped onto the class symbol, which is SymbolKind.Class and not appropriate
// for a callable. Defaults are receiver-aligned (null prepended) the same way
// `collectClassMethod` aligns method defaults.
function ctorToInitFunction(classNode: Node, classGenerics: string, ctorNode: Node): Node {
	const cd = ctorNode.data as ConstructorDeclData;
	const className = (classNode.data as ClassDeclData).className;
	const initName = `${className}_init`;
	const receiverType = classGenerics !== "" ? `${className}<${classGenerics}>` : className;
	const newParams: string[] = ["this"];
	const newParamTypes: string[] = [receiverType];
	for (const p of cd.ctorParams) { newParams.push(p); }
	for (const t of cd.ctorParamTypes) { newParamTypes.push(t); }
	// Receiver-align defaults (same pattern Bug 8 fix uses for method defaults):
	// fillDefaults expects defaults[0] to be the (always-null) receiver slot.
	let defaults: Node[] = [];
	if (cd.ctorDefaults !== null && cd.ctorDefaults.length > 0) {
		defaults.push(null as unknown as Node);
		for (const def of cd.ctorDefaults) { defaults.push(def); }
	}
	const fnData: NodeData = {
		fnName: initName,
		params: newParams,
		fnParamTypes: newParamTypes,
		fnBody: cd.ctorBody,
		fnFlags: "",
		fnReturnType: "void",
		fnDefaults: defaults,
		nativeName: "",
		nameLocation: ctorNode.location,
	};
	const fnNode = createNodeAt(NodeKind.FunctionDecl, fnData, ctorNode.location);
	// Carry the resolved Function type from the ConstructorDecl (set in
	// resolveConstructorType). The signature already excludes the receiver
	// — codegen's genFunctionDecl reads the param list from `fnData.params`
	// (which DOES include "this") and types from `fnNode.nodeType.typeChildren`
	// (which doesn't), so we widen typeChildren by prepending the receiver
	// type to keep the two indexes aligned.
	if (ctorNode.nodeType !== null && ctorNode.nodeType.typeChildren !== null) {
		const ctorType = ctorNode.nodeType;
		// Receiver type is the class's declared type (Ref<Struct>). Widening
		// typeChildren with the right `this` type keeps `genFunctionDecl` /
		// `shouldIndirectParam` honest — without it, `this` codegens as `void*`.
		const classType = classNode.nodeType !== null ? classNode.nodeType : unknownType();
		const widenedChildren: any[] = [classType];
		for (const t of ctorType.typeChildren) { widenedChildren.push(t); }
		const widenedNames: string[] = ["this"];
		for (const n of ctorType.typeNames) { widenedNames.push(n); }
		fnNode.nodeType = createFunction(widenedChildren, widenedNames, voidType());
	} else {
		fnNode.nodeType = createFunction([], newParams, voidType());
	}
	// Synthesize a Symbol so `genFunctionDecl` treats this as exported (cross-module
	// callable) and `mangledFunctionName` produces the same name shape as method
	// lifts. mutatedParams is left at 0 — ctor params don't currently feed
	// param-mutation analysis (it runs over functions' bodies, not ctors). If
	// that becomes a problem, propagate the bitfield here from the class symbol.
	const initSym = makeSymbol(initName, SymbolKind.Function, fnNode.nodeType, false);
	setFlag(initSym, SymbolFlag.Exported);
	initSym.location = ctorNode.location;
	initSym.declNode = fnNode;
	if (defaults.length > 0) initSym.defaultParams = defaults;
	fnNode.resolvedSym = initSym;
	fnNode.flags = ctorNode.flags;
	fnNode.paramLocations = ctorNode.paramLocations;
	fnNode.typeExpr = ctorNode.typeExpr;
	fnNode.typeExprs = ctorNode.typeExprs;
	return fnNode;
}

// Re-wrap a lifted FunctionDecl in the original DecoratedDecl shell so the
// decorator info (name + args) keeps applying post-lift. genDecl reads the
// wrapper, so keeping it preserves `@decorator` semantics.
function rewrapDecorated(member: Node, dd: DecoratedDeclData, liftedFn: Node): Node {
	const newDecorated = createNodeAt(NodeKind.DecoratedDecl, {
		decorators: dd.decorators,
		decoratedNode: liftedFn,
	}, member.location);
	newDecorated.flags = member.flags;
	newDecorated.resolvedSym = liftedFn.resolvedSym;
	return newDecorated;
}

// Walk `class` / `actor` body, pull out every MethodDecl + ConstructorDecl
// (including DecoratedDecl wrappers), produce FunctionDecls. Returns the new
// body (PropertyDecl + non-callable DecoratedDecls only) plus the collected
// functions to insert at module top-level.
function liftMethodsFromClassBody(classNode: Node, body: Node[]): { body: Node[], lifted: Node[] } {
	const newBody: Node[] = [];
	const lifted: Node[] = [];
	// Class-level generics are stored side-band by the parser, keyed by the
	// class name. Methods + ctors built before resolution need it to render
	// the receiver type as `Foo<T>` rather than `Foo`.
	const className = classNode.kind === NodeKind.ClassDecl
		? (classNode.data as ClassDeclData).className
		: "";
	const classGenerics = className !== "" ? getGenericDecl(className) : "";
	for (const member of body) {
		match (member.kind) {
			NodeKind.MethodDecl => {
				lifted.push(methodToFunctionDecl(member));
			},
			NodeKind.ConstructorDecl => {
				lifted.push(ctorToInitFunction(classNode, classGenerics, member));
			},
			NodeKind.DecoratedDecl => {
				const dd = member.data as DecoratedDeclData;
				const inner = dd.decoratedNode;
				const innerKind = inner !== null ? inner.kind : -1;
				if (innerKind === NodeKind.MethodDecl) {
					lifted.push(rewrapDecorated(member, dd, methodToFunctionDecl(inner)));
				} else if (innerKind === NodeKind.ConstructorDecl) {
					lifted.push(rewrapDecorated(member, dd, ctorToInitFunction(classNode, classGenerics, inner)));
				} else {
					newBody.push(member);
				}
			},
			_ => { newBody.push(member); },
		};
	}
	return { body: newBody, lifted };
}

// ===== Entry Point =====

export function lowerMethodToFunction(program: Node, ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const newStmts: Node[] = [];
	for (const stmt of pd.programStmts) {
		// Class / Actor at top level — possibly wrapped in ExportDecl. The
		// wrapper itself stays in `programStmts`; we only mutate the inner
		// classBody/actorBody in place and append the lifted FunctionDecls.
		let target = stmt;
		if (target.kind === NodeKind.ExportDecl) {
			target = (target.data as ExportDeclData).exportedDecl;
		}
		if (target === null) {
			newStmts.push(stmt);
			continue;
		}
		if (target.kind === NodeKind.ClassDecl) {
			const cd = target.data as ClassDeclData;
			const result = liftMethodsFromClassBody(target, cd.classBody);
			cd.classBody = result.body;
			newStmts.push(stmt);
			for (const fn of result.lifted) { newStmts.push(fn); }
			continue;
		}
		if (target.kind === NodeKind.ActorDecl) {
			// Actors register their methods as extension functions too; lifting
			// them gives the same uniform top-level FunctionDecl shape. The
			// `actorLower` transform has already rewritten send/call sites, so
			// no method users remain on the actor body.
			const ad = target.data as ActorDeclData;
			const result = liftMethodsFromClassBody(target, ad.actorBody);
			ad.actorBody = result.body;
			newStmts.push(stmt);
			for (const fn of result.lifted) { newStmts.push(fn); }
			continue;
		}
		newStmts.push(stmt);
	}
	pd.programStmts = newStmts;
	return program;
}
