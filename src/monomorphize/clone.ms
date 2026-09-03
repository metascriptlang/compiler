// Monomorphization clone/substitute utilities — shared by collect + instantiate.
//
// These three functions (monoCloneNode, monoSubstAnnotation, monoConcreteTypeName)
// are pure helpers with no dependency on the collect pass's own state. They
// live here so both the checker's on-demand instantiation path
// (src/checker/instantiate.ms) and the monomorphize collect pass
// (src/monomorphize/collect.ms) can use them without a circular import.

import { Node, NodeFlag, makeLocRange, createNodeAt, SourceLocation, Symbol, SymbolKind, Type, TypeKind } from "../ast/node";
import { isResult, getResultOkType, getResultErrType, isAtomicRef, emptyType } from "../checker/types";
import { FieldXform, rebuildNodeData, pkSamples, pkDumpNode } from "../ast/fieldspec";

// ===== Clone Mode =====
// Mono: monomorphization (copies nodeType, drops typeExpr — used by generic instantiation)
// Check: dbTypeCheck (copies typeExpr for resolvePass, drops nodeType/resolvedSym so checker re-populates)
export enum CloneMode {
	Mono,
	Check,
}

// Module-level mode: set by the public entry points (monoCloneNode, cloneNodeForCheck),
// read by copyNodeMeta deep inside the recursive traversal. Single-threaded + non-reentrant
// clone assumption — each public call save/restores.
let currentCloneMode: CloneMode = CloneMode.Mono;

// ===== Public Entry Points =====

export function monoCloneNode(node: Node): Node {
	const saved = currentCloneMode;
	currentCloneMode = CloneMode.Mono;
	const result = cloneNodeImpl(node);
	currentCloneMode = saved;
	return result;
}

export function cloneNodeForCheck(node: Node): Node {
	const saved = currentCloneMode;
	currentCloneMode = CloneMode.Check;
	const result = cloneNodeImpl(node);
	currentCloneMode = saved;
	return result;
}

// ===== Clone — deep AST copy =====
//
// The per-kind payload walk lives in ast/fieldspec.ms (rebuildNodeData) — this
// file only supplies the xform (recursive clone for refs, copies for arrays,
// identity for scalars) and the mode-dependent node META copy (copyNodeMeta).
// Unification fixed three latent gaps in the old hand-rolled switch:
//   - WhileStmt.whileLabel is now carried (was silently dropped)
//   - PropertyDecl.propInitializer is now cloned (was shared with the original)
//   - TypeGeneric/TypeArray/TypeUnion/TypeIntersection/TypeFunction/TypeObject/
//     TestDecl/ActorDecl get real deep clones (fell through to a shared-payload
//     fallback before)
// and clone now copies the FULL source location (endLine/endColumn were
// dropped). All of it is pinned by the exhaustive per-kind payload roundtrip
// test at the bottom of this file.

// Copy node-level metadata from source to clone. Behavior depends on currentCloneMode.
//
// Shared (both modes):
//   - Clears NodeFlag.Sem so post-clone re-check actually runs
//     (monoCheckInstantiatedBody / callCheckFunctionBody). Without this, the Sem
//     flag from the first-check pass makes checkExpr early-return, and nested
//     generic method calls in cloned bodies never get re-resolved.
//
// Mono (monomorphization):
//   - Copies nodeType (downstream passes need resolved type info; replaceTypeVars
//     substitutes it before re-check via substNodeLocal).
//   - Copies typeArg (explicit `<K, V>` strings on NewExpr/CallExpr). Without this,
//     `new HashMap<K, V>()` inside a cloned generic wrapper would lose its type args
//     and fall back to a location-keyed side channel holding the original strings,
//     defeating substitution. replaceTypeVars substitutes this field too.
//   - Skips resolvedSym (name rewriting path, re-resolved via shared IdentCache).
//   - Skips typeExpr/typeExprs (LSP side channel — mono clones don't need positions).
//
// Check (dbTypeCheck clone-before-mutate):
//   - Skips nodeType (checker will re-populate during resolvePass + checkPass).
//   - Skips resolvedSym (checker will re-populate).
//   - Copies typeExpr/typeExprs (resolvePass reads them for type-position annotation).
//   - Copies typeArg, paramLocations, comments (parser-time side channels the
//     checker reads during re-check).
//
// The mode distinction ensures that dbTypeCheck can safely mutate the clone without
// poisoning dbParse's cached immutable tree, while still giving the checker the
// positioned type AST it needs for LSP hover/goto.
function copyNodeMeta(src: Node, dst: Node): Node {
	// Clear Sem flag on mono clones so monoCheckInstantiatedBody can actually
	// re-check the cloned body. Without this, the Sem flag from the original
	// (set during the first check pass) makes checkExpr early-return and nested
	// generic method calls — e.g. `m.set(...)` where m had type HashMap<K,V> but
	// now has concrete HashMap<string,number> — never get re-resolved to their
	// concrete instantiations. On-demand instantiation (callInstantiateGeneric)
	// at checkExprPass.ms only fires during the re-check. This unlocks that.
	dst.flags = src.flags & ~NodeFlag.Sem;
	if (currentCloneMode === CloneMode.Mono) {
		dst.nodeType = src.nodeType;
		// Preserve explicit generic type args so they survive monomorphize cloning.
		// Without this, `new HashMap<K, V>()` inside a cloned generic wrapper would
		// lose its type args — the checker would fall back to a location-keyed
		// side channel that still holds the original "K, V" strings, defeating
		// substitution. replaceTypeVars substitutes this field in substNodeLocal.
		dst.typeArg = src.typeArg;
	} else {
		// Check mode: preserve all parse-time side channels the checker reads
		// (typeExpr/typeExprs for resolvePass, paramLocations for function
		// declarations, comments for LSP hover doc strings, typeArg for
		// explicit generic type arguments).
		// nodeType/resolvedSym are intentionally NOT copied — the checker
		// populates them fresh during check.
		dst.typeExpr = src.typeExpr;
		dst.typeExprs = src.typeExprs;
		dst.paramLocations = src.paramLocations;
		dst.comments = src.comments;
		dst.typeArg = src.typeArg;
	}
	// Enum member access was rewritten by the checker from `E.M` (MemberExpr)
	// to `Identifier "E_M"` whose mangled name is deliberately never bound in
	// scope — its only resolution path is this resolvedSym. Both clone modes must
	// carry it by reference (Nim freshGenSyms leaves non-gensym syms untouched):
	// Check mode for comptime/macro re-check, Mono mode for generic instantiation
	// (else a cloned `E.M` in a generic body re-resolves by name and fails).
	// See NIM-REF.md §1 "Enum member repr & generic-instantiation survival".
	if (src.resolvedSym !== null && src.resolvedSym.symbolKind === SymbolKind.EnumMember) {
		dst.resolvedSym = src.resolvedSym;
		dst.nodeType = src.nodeType;
	} else if (src.resolvedSym !== null && (src.flags & NodeFlag.BoundSym) !== 0) {
		// bindSym: pre-bound symbol travels by reference; checker re-derives nodeType.
		dst.resolvedSym = src.resolvedSym;
	}
	return dst;
}

const cloneXform: FieldXform = {
	node: (n: Node | null): Node | null => { return n !== null ? cloneNodeImpl(n) : null; },
	nodes: (a: (Node | null)[] | null): (Node | null)[] => {
		const out: (Node | null)[] = [];
		if (a !== null) { for (const x of a) { out.push(x !== null ? cloneNodeImpl(x) : null); } }
		return out;
	},
	nodesNested: (a: (Node | null)[][] | null): (Node | null)[][] => {
		const out: (Node | null)[][] = [];
		if (a !== null) { for (const row of a) { const r: (Node | null)[] = []; if (row !== null) { for (const x of row) { r.push(x !== null ? cloneNodeImpl(x) : null); } } out.push(r); } }
		return out;
	},
	typ: (t: Type | null): Type | null => { return t; },
	str: (s: string): string => { return s; },
	strArr: (a: string[] | null): string[] => {
		const out: string[] = [];
		if (a !== null) { for (const s of a) { out.push(s); } }
		return out;
	},
	integer: (v: int64): int64 => { return v; },
	float: (v: float64): float64 => { return v; },
	bool: (b: boolean): boolean => { return b; },
	loc: (l: SourceLocation | null): SourceLocation | null => { return l; },
	locs: (l: SourceLocation[] | null): SourceLocation[] => {
		const out: SourceLocation[] = [];
		if (l !== null) { for (const x of l) { out.push(x); } }
		return out;
	},
	floats: (a: number[] | null): number[] => {
		const out: number[] = [];
		if (a !== null) { for (const v of a) { out.push(v); } }
		return out;
	},
};

function cloneNodeImpl(node: Node | null): Node {
	if (node === null) return null as unknown as Node;
	const loc = node.location;
	return copyNodeMeta(node, createNodeAt(node.kind, rebuildNodeData(node, cloneXform), makeLocRange(loc.line, loc.column, loc.endLine, loc.endColumn)));
}


// ===== Substitute — rewrite generic param names in string-form type annotations =====

function monoIsAlphaNumOrUnderscore(ch: string): boolean {
	if (ch === "_") return true;
	if (ch === "a" || ch === "b" || ch === "c" || ch === "d" || ch === "e" || ch === "f" || ch === "g" || ch === "h" || ch === "i" || ch === "j" || ch === "k" || ch === "l" || ch === "m" || ch === "n" || ch === "o" || ch === "p" || ch === "q" || ch === "r" || ch === "s" || ch === "t" || ch === "u" || ch === "v" || ch === "w" || ch === "x" || ch === "y" || ch === "z") return true;
	if (ch === "A" || ch === "B" || ch === "C" || ch === "D" || ch === "E" || ch === "F" || ch === "G" || ch === "H" || ch === "I" || ch === "J" || ch === "K" || ch === "L" || ch === "M" || ch === "N" || ch === "O" || ch === "P" || ch === "Q" || ch === "R" || ch === "S" || ch === "T" || ch === "U" || ch === "V" || ch === "W" || ch === "X" || ch === "Y" || ch === "Z") return true;
	if (ch === "0" || ch === "1" || ch === "2" || ch === "3" || ch === "4" || ch === "5" || ch === "6" || ch === "7" || ch === "8" || ch === "9") return true;
	return false;
}

export function monoSubstAnnotation(annotation: string, paramName: string, concreteTypeName: string): string {
	if (annotation === "") return "";
	if (annotation === paramName) return concreteTypeName;
	let result = "";
	let i = 0;
	while (i < annotation.byteLength) {
		let isMatch = true;
		if (i + paramName.byteLength > annotation.byteLength) { isMatch = false; } else {
			for (let pi = 0; pi < paramName.byteLength; pi += 1) { if (annotation.charAt(i + pi) !== paramName.charAt(pi)) { isMatch = false; } }
		}
		if (isMatch) {
			let prevOk = true;
			let nextOk = true;
			if (i > 0) { prevOk = !monoIsAlphaNumOrUnderscore(annotation.charAt(i - 1)); }
			const nextPos = i + paramName.byteLength;
			if (nextPos < annotation.byteLength) { nextOk = !monoIsAlphaNumOrUnderscore(annotation.charAt(nextPos)); }
			if (prevOk && nextOk) { result = result + concreteTypeName; i = i + paramName.byteLength; } else { result = result + annotation.charAt(i); i += 1; }
		} else { result = result + annotation.charAt(i); i += 1; }
	}
	return result;
}

// Type-to-string for annotation substitution (human-readable MetaScript type names).
// Used by substituteAnnotations to replace generic params in type annotations.
// NOT for C name mangling — use registry.ms:monoTypeKey for that.
export function monoConcreteTypeName(t: Type | null): string {
	if (t === null) return "unknown";
	if (isResult(t)) return `Result<${monoConcreteTypeName(getResultOkType(t))}, ${monoConcreteTypeName(getResultErrType(t))}>`;
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		// Plain Ref strips to its pointee (the class-annotation convention:
		// "SomeClass" re-resolves to Ref<Struct> by itself). An ATOMIC Ref
		// (Arc<T>) must keep its wrapper: "Arc<T>" is the spelling
		// resolveAnnotation understands (resolvePass createArc), and stripping
		// it turned `T := Arc<P>` in `Promise<T>` into bare `Promise<P>`
		// during generic-body re-check — the 406 spawn-twin mismatch.
		TypeKind.Ref => isAtomicRef(t)
			? `Arc<${monoConcreteTypeName(t.typeReturn)}>`
			: monoConcreteTypeName(t.typeReturn),
		TypeKind.Ptr => `Ptr<${monoConcreteTypeName(t.typeReturn)}>`,
		TypeKind.Array => `Array<${monoConcreteTypeName(t.typeReturn)}>`,
		TypeKind.Struct | TypeKind.Enum => t.typeName,
		TypeKind.GenericInstance => {
			let name = t.typeName;
			let i = 0;
			while (i < t.typeChildren.length) {
				name = name + (i === 0 ? "<" : ", ") + monoConcreteTypeName(t.typeChildren[i]);
				i = i + 1;
			}
			return name + ">";
		},
		TypeKind.Union => {
			// Named DU alias (Either, Result, user-declared union): use the name —
			// it resolves back to the same Union via type-alias lookup.
			if (t.typeName !== "") return t.typeName;
			// Anonymous union: emit literal `A | B | C` so the substituted
			// annotation roundtrips through `resolveAnnotation` back to a
			// Union with the same children. The previous "Union" placeholder
			// didn't resolve to anything and triggered the same `_function`-
			// style mono-naming divergence Bug 5a fixed for Function types.
			let lit = "";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) lit = lit + " | ";
				lit = lit + monoConcreteTypeName(t.typeChildren[i]);
				i = i + 1;
			}
			return lit !== "" ? lit : "unknown";
		},
		TypeKind.Conditional => {
			// `T extends U ? A : B` — typeChildren = [check, extends, true, false].
			// Most conditionals evaluate to one branch during substitution
			// (`evaluateConditionalType`); reach this arm only when generic
			// params still leak through. Emit the literal so the parser can
			// reconstruct the Conditional shape on re-resolution.
			if (t.typeChildren.length < 4) return "unknown";
			return monoConcreteTypeName(t.typeChildren[0])
				+ " extends " + monoConcreteTypeName(t.typeChildren[1])
				+ " ? " + monoConcreteTypeName(t.typeChildren[2])
				+ " : " + monoConcreteTypeName(t.typeChildren[3]);
		},
		TypeKind.Tuple => {
			// Roundtrip the `[A, B]` literal through resolveAnnotation back to a Tuple —
			// "unknown" would erase the element types and drop per-element DRC cleanup.
			let lit = "";
			for (const child of t.typeChildren) {
				if (lit !== "") lit = lit + ", ";
				lit = lit + monoConcreteTypeName(child);
			}
			return "[" + lit + "]";
		},
		TypeKind.Function => {
			// Function type substituted into a generic body has to roundtrip
			// through `resolveAnnotation` after the substitution string is
			// re-parsed. The previous "Function" placeholder didn't roundtrip
			// — there is no `Function` symbol in scope, so the re-resolved
			// type came back as Unknown and the generic instance ended up
			// with `void*` fields plus a `_Function`-suffixed mangled name
			// that disagreed with the caller-side `_function` lowercase
			// name produced by `monoTypeKey`. Emit the function-type literal
			// (the same surface syntax the user writes) so the parser
			// reconstructs an equivalent `Function` Type and downstream
			// mangling lines up with the caller's mono path.
			let sig = "(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) sig = sig + ", ";
				const paramName = i < t.typeNames.length && t.typeNames[i].length > 0 ? t.typeNames[i] : `p${i}`;
				sig = sig + paramName + ": " + monoConcreteTypeName(t.typeChildren[i]);
				i = i + 1;
			}
			const retName = t.typeReturn !== null ? monoConcreteTypeName(t.typeReturn) : "void";
			return "(" + sig + ") => " + retName + ")";
		},
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		_ => "unknown",
	};
}

test "clone: exhaustive per-kind payload roundtrip" {
	// Mirrors the pack's exhaustive test but through monoCloneNode: every
	// NodeKind sample must survive a deep clone payload-intact (kind +
	// full location + every per-kind field). Header extras (flags/typeArg/
	// typeExpr/nodeType/resolvedSym) are skipped — copyNodeMeta legitimately
	// differs per CloneMode. rootSym is null here because resolvedSym only
	// prints under withMeta, which this comparison leaves off.
	const nt = emptyType();
	nt.kind = TypeKind.Int32;
	nt.typeName = "int32";
	const ct = emptyType();
	ct.kind = TypeKind.Boolean;
	ct.typeName = "bool";
	const samples = pkSamples(null as unknown as Symbol, nt, ct);
	assert samples.length === 91;
	for (let i = 0; i < samples.length; i += 1) {
		assert (samples[i].kind as int32) === i;
	}
	for (let i = 0; i < samples.length; i += 1) {
		const c = monoCloneNode(samples[i]);
		const da = pkDumpNode(samples[i], false);
		const db = pkDumpNode(c, false);
		if (da !== db) {
			console.log(`kind ${i} clone mismatch`);
			console.log(`  orig: ${da.slice(0, 300)}`);
			console.log(`  got : ${db.slice(0, 300)}`);
			assert false;
		}
	}
}
