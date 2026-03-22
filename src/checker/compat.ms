// Type Compatibility - table-driven assignability checking

import { Type, TypeKind } from "../ast/node";
import { isNumeric, isIntegerType, integerRank, skipModifier, typeNameOf, numberType, stringType, booleanType, voidType, nullType, unknownType, errorType, createPrimitive, createArray, createFunction, createStruct, createUnion, createEnum, createResult, createRef, createPtr, createDistinct, createGenericParam, createSizedArray, createSpan, getMinArity } from "./types";


// ===== Assignability =====

let _assignDepth = 0;
export function isAssignable(source: Type, target: Type): boolean {
	if (_assignDepth > 20) return true;
	_assignDepth = _assignDepth + 1;
	const result = isAssignableInner(source, target);
	_assignDepth = _assignDepth - 1;
	return result;
}

function isAssignableInner(source: Type, target: Type): boolean {
	// Reference parity: sink and lent modifiers are transparent ownership modifiers — unwrap before comparing
	// Standard reference implementation skips these modifiers during type relationship checks.
	source = skipModifier(source);
	target = skipModifier(target);

	// Same kind is always compatible
	if (source.kind === target.kind) {
		return match (source.kind) {
			TypeKind.SizedArray => source.typeFlags === target.typeFlags && isAssignable(source.typeReturn, target.typeReturn),
			TypeKind.Array | TypeKind.Span | TypeKind.Ref | TypeKind.Ptr => isAssignable(source.typeReturn, target.typeReturn),
			TypeKind.Function => isFunctionAssignable(source, target),
			TypeKind.Struct => isObjectAssignable(source, target),
			TypeKind.Enum | TypeKind.Distinct => source.typeName === target.typeName,
			TypeKind.GenericInstance => {
				// Structural compatibility: compare type args pairwise
				const limit = source.typeChildren.length < target.typeChildren.length ? source.typeChildren.length : target.typeChildren.length;
				for (let gi = 0; gi < limit; gi += 1) {
					if (!isAssignable(source.typeChildren[gi], target.typeChildren[gi])) return false;
				}
				return source.typeName === target.typeName;
			},
			_ => true,
		};
	}

	// Implicit coercion to Span: T[] -> Span<T> or T[N] -> Span<T> or string -> Span<char>
	if (target.kind === TypeKind.Span) {
		if (source.kind === TypeKind.Array || source.kind === TypeKind.SizedArray) {
			return isAssignable(source.typeReturn, target.typeReturn);
		}
		if (source.kind === TypeKind.String && target.typeReturn !== null && target.typeReturn.kind === TypeKind.Char) {
			return true;
		}
	}

	// Var (out param) unwrap: T -> Var<T> (caller passes T, callee gets T*)
	if (target.kind === TypeKind.Var && target.typeReturn !== null) {
		return isAssignable(source, target.typeReturn);
	}

	// Implicit borrow promotion: T -> Borrow<T> (zero-copy const pointer)
	if (target.kind === TypeKind.Borrow && target.typeReturn !== null) {
		return isAssignable(source, target.typeReturn);
	}

	// Unknown on either side: inference pending, allow
	if (source.kind === TypeKind.Unknown || target.kind === TypeKind.Unknown) {
		return true;
	}

	// GenericParam on either side: unresolved generic, allow
	if (source.kind === TypeKind.GenericParam || target.kind === TypeKind.GenericParam) {
		return true;
	}

	// Error type is compatible with everything (suppress cascading errors)
	if (source.kind === TypeKind.Error || target.kind === TypeKind.Error) {
		return true;
	}

	// TypeReference: unresolved forward/cross-module type — compare by canonical name.


	// null assignable to nullable targets (Object, Array, SizedArray, Span, Function, Ref, Ptr)
	if (source.kind === TypeKind.Null) {
		return match (target.kind) {
			TypeKind.Struct | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Function | TypeKind.Ref | TypeKind.Ptr => true,
			_ => false,
		};
	}

	// Numeric widening: any numeric type assignable to Number
	if (isNumeric(source) && target.kind === TypeKind.Number) {
		return true;
	}

	// Integer → float64 widening (lossless for int32 range)
	if (isIntegerType(source) && target.kind === TypeKind.Float64) {
		return true;
	}

	// Ref<T> → T auto-deref: self-referential fields are promoted to Ref<T>,
	// but passing them to functions expecting T should work transparently
	if (source.kind === TypeKind.Ref && source.typeReturn !== null) {
		return isAssignable(source.typeReturn, target);
	}

	// String → CString implicit coercion (zero-copy pointer extraction)
	if (source.kind === TypeKind.String && target.kind === TypeKind.CString) {
		return true;
	}

	// Source is union: all members must be assignable to target
	if (source.kind === TypeKind.Union) {
		for (const member of source.typeChildren) {
			if (!isAssignable(member, target)) return false;
		}
		return true;
	}

	// Target is union: source must be assignable to at least one member
	if (target.kind === TypeKind.Union) {
		for (const member of target.typeChildren) {
			if (isAssignable(source, member)) return true;
		}
		return false;
	}

	return false;
}

// ===== Standard Conversion Check (standard reference implementation parity) =====
// Returns true when source needs an explicit cast to target in C codegen.
// Used by checker to insert HiddenStdConv nodes at call argument positions.
export function needsStdConv(source: Type, target: Type): boolean {
	if (source === null || target === null) return false;
	// Var (out param): unwrap to inner type for conversion check
	if (target.kind === TypeKind.Var && target.typeReturn !== null) {
		return needsStdConv(source, target.typeReturn);
	}
	if (source.kind === target.kind) return false;
	// Numeric widening/narrowing: int32→number, float32→number, etc.
	if (isNumeric(source) && isNumeric(target)) return true;
	// Array/SizedArray/String to Span coercion requires struct initializer
	if (target.kind === TypeKind.Span) {
		if (source.kind === TypeKind.Array || source.kind === TypeKind.SizedArray) return true;
		if (source.kind === TypeKind.String && target.typeReturn !== null && target.typeReturn.kind === TypeKind.Char) return true;
	}
	// String → CString requires msCStr extraction
	if (source.kind === TypeKind.String && target.kind === TypeKind.CString) return true;
	// Borrow promotion: T → Borrow<T> (take address)
	if (target.kind === TypeKind.Borrow && target.typeReturn !== null) {
		if (source.kind !== TypeKind.Borrow) return true;
	}
	return false;
}

// Function assignability: contravariant params, covariant return
function isFunctionAssignable(source: Type, target: Type): boolean {
	if (source.typeChildren.length !== target.typeChildren.length) return false;
	// Check params (contravariant: target params assignable to source params)
	let i = 0;
	for (const sourceParam of source.typeChildren) {
		if (!isAssignable(target.typeChildren[i], sourceParam)) return false;
		i += 1;
	}
	// Check return (covariant)
	if (source.typeReturn !== null && target.typeReturn !== null) {
		return isAssignable(source.typeReturn, target.typeReturn);
	}
	return true;
}

// Object assignability: nominal first, then structural (source has all target properties)
function isObjectAssignable(source: Type, target: Type): boolean {
	// Nominal: same typeName means same type (handles self-referencing types like Type, Scope)
	if (source.typeName !== "" && source.typeName === target.typeName) return true;
	let targetIdx = 0;
	for (const targetProp of target.typeNames) {
		// Look for matching prop in source
		let found = false;
		let si = 0;
		for (const sourceProp of source.typeNames) {
			if (sourceProp === targetProp) {
				found = true;
				if (si < source.typeChildren.length && targetIdx < target.typeChildren.length) {
					if (!isAssignable(source.typeChildren[si], target.typeChildren[targetIdx])) {
						return false;
					}
				}
			}
			si += 1;
		}
		if (!found) return false;
		targetIdx += 1;
	}
	return true;
}

// ===== Overload Resolution =====

export enum TypeRelation {
	None,           // 0 - no match
	Convertible,    // 1 - requires conversion
	IntConv,        // 2 - int/float conversion
	Subtype,        // 3 - inheritance/structural
	Generic,        // 4 - generic param match / inference pending
	FromLiteral,    // 5 - from literal (proven safe)
	Exact,          // 6 - exact match
}

let _relationDepth = 0;
export function typeRelation(formal: Type, actual: Type): TypeRelation {
	if (_relationDepth > 20) return TypeRelation.Generic;
	_relationDepth = _relationDepth + 1;
	const result = typeRelationInner(formal, actual);
	_relationDepth = _relationDepth - 1;
	return result;
}

function typeRelationInner(formal: Type, actual: Type): TypeRelation {
	// Same kind: dispatch on type-specific rules
	if (formal.kind === actual.kind) {
		return match (formal.kind) {
			TypeKind.Struct => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				if (isObjectAssignable(actual, formal)) return TypeRelation.Subtype;
				return TypeRelation.None;
			},
			TypeKind.Enum | TypeKind.Distinct => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				return TypeRelation.None;
			},
			TypeKind.SizedArray => {
				if (formal.typeFlags !== actual.typeFlags) return TypeRelation.None;
				if (formal.typeReturn !== null && actual.typeReturn !== null) {
					const elemRel = typeRelation(formal.typeReturn, actual.typeReturn);
					if (elemRel === TypeRelation.None) return TypeRelation.None;
					return elemRel;
				}
				return TypeRelation.Exact;
			},
			TypeKind.Array | TypeKind.Span | TypeKind.Ref | TypeKind.Ptr => {
				if (formal.typeReturn !== null && actual.typeReturn !== null) {
					const elemRel = typeRelation(formal.typeReturn, actual.typeReturn);
					if (elemRel === TypeRelation.None) return TypeRelation.None;
					return elemRel;
				}
				return TypeRelation.Exact;
			},
			TypeKind.GenericInstance => {
				// Structural type arg comparison (Result, Promise, Map, Set, user generics)
				if (formal.typeName !== actual.typeName) return TypeRelation.None;
				const giLimit = formal.typeChildren.length < actual.typeChildren.length ? formal.typeChildren.length : actual.typeChildren.length;
				for (let gi = 0; gi < giLimit; gi += 1) {
					const argRel = typeRelation(formal.typeChildren[gi], actual.typeChildren[gi]);
					if (argRel === TypeRelation.None) return TypeRelation.None;
				}
				return TypeRelation.Exact;
			},
			_ => TypeRelation.Exact,
		};
	}
	// Var (out param) unwrap: formal is Var<T>, actual is T → match inner
	if (formal.kind === TypeKind.Var && formal.typeReturn !== null) {
		return typeRelation(formal.typeReturn, actual);
	}

	// Unknown = inference pending
	if (formal.kind === TypeKind.Unknown || actual.kind === TypeKind.Unknown) {
		return TypeRelation.Generic;
	}
	// GenericParam = inference pending
	if (formal.kind === TypeKind.GenericParam || actual.kind === TypeKind.GenericParam) {
		return TypeRelation.Generic;
	}
	// Implicit coercion to Span: T[] -> Span<T> or T[N] -> Span<T>
	if (formal.kind === TypeKind.Span) {
		if (actual.kind === TypeKind.Array || actual.kind === TypeKind.SizedArray) {
			const elemRel = typeRelation(formal.typeReturn, actual.typeReturn);
			if (elemRel !== TypeRelation.None) return TypeRelation.Subtype;
		}
	}
	// Error type = suppress cascading
	if (formal.kind === TypeKind.Error || actual.kind === TypeKind.Error) {
		return TypeRelation.Exact;
	}
	// Numeric widening: sized → Number
	if (isNumeric(actual) && formal.kind === TypeKind.Number) {
		return TypeRelation.IntConv;
	}
	// Int-to-int widening: smaller int → larger int (e.g., int32 → int64)
	// Safe widening (rank increases) and same-rank conversions (e.g., int32 → uint32).
	// Narrowing (rank decreases) requires explicit cast.
	if (isNumeric(actual) && isNumeric(formal) && actual.kind !== formal.kind
		&& integerRank(actual) <= integerRank(formal)) {
		return TypeRelation.IntConv;
	}
	// FromLiteral: Number/Float64 → sized numeric formal (number and float64 are both IEEE 754 double)
	if (isNumeric(formal) && (actual.kind === TypeKind.Number || actual.kind === TypeKind.Float64)) {
		return TypeRelation.FromLiteral;
	}
	// Null to nullable
	if (actual.kind === TypeKind.Null) {
		if (formal.kind === TypeKind.Struct || formal.kind === TypeKind.Array ||
			formal.kind === TypeKind.SizedArray || formal.kind === TypeKind.Span ||
			formal.kind === TypeKind.Function || formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr) {
			return TypeRelation.Subtype;
		}
	}
	// Union target: best match
	if (formal.kind === TypeKind.Union) {
		let best = TypeRelation.None;
		for (const member of formal.typeChildren) {
			const rel = typeRelation(member, actual);
			if ((rel as number) > (best as number)) { best = rel; }
		}
		return best;
	}
	return TypeRelation.None;
}

// Score a candidate function against actual arguments.
// Returns sum of TypeRelation values, or -1 if any param doesn't match.
export function scoreCandidate(paramTypes: Type[], argTypes: Type[]): number {
	if (paramTypes.length !== argTypes.length) return -1;
	let score = 0;
	for (let i = 0; i < paramTypes.length; i += 1) {
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) return -1;
		score = score + (rel as number);
	}
	return score;
}

// ===== Standard-Aligned Overload Resolution (Priority-Based) =====

// Candidate scoring with per-category counters (Standard reference pattern).
// All 7 fields included upfront so struct never changes (DRC #32 safe).
export interface CandidateScore {
	exactMatches: number;       // isEqual matches
	genericMatches: number;     // isGeneric / isInferred matches
	subtypeMatches: number;     // isSubtype / isSubrange matches
	intConvMatches: number;     // isIntConv + isFromIntLit (Standard weight: += 256)
	convMatches: number;        // isConvertible (converters — always 0 for now)
	inheritancePenalty: number; // class hierarchy depth (-1 = inactive)
	calleeScope: number;        // scope depth where candidate found (higher = inner)
}

export function emptyCandidateScore(): CandidateScore {
	return {
		exactMatches: 0, genericMatches: 0, subtypeMatches: 0,
		intConvMatches: 0, convMatches: 0,
		inheritancePenalty: -1, calleeScope: 0,
	};
}

export function isNoMatch(score: CandidateScore): boolean {
	return score.exactMatches === -1;
}

// Score a candidate function against actual arguments (Standard-aligned priority counters).
// Maps TypeRelation → counter increments matching standard reference implementation.
// minArity: minimum required args (default = paramTypes.length, i.e. all required).
export function scoreCandidatePriority(paramTypes: Type[], argTypes: Type[], minArity: number): CandidateScore {
	const score = emptyCandidateScore();
	if (argTypes.length < minArity || argTypes.length > paramTypes.length) {
		score.exactMatches = -1;
		return score;
	}
	// Score only provided args (default-filled params don't contribute)
	for (let i = 0; i < argTypes.length; i += 1) {
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) {
			score.exactMatches = -1;
			return score;
		}
		match (rel) {
			TypeRelation.Exact => { score.exactMatches = score.exactMatches + 1; },
			TypeRelation.FromLiteral => { score.intConvMatches = score.intConvMatches + 256; },
			TypeRelation.Generic => { score.genericMatches = score.genericMatches + 1; },
			TypeRelation.Subtype => { score.subtypeMatches = score.subtypeMatches + 1; },
			TypeRelation.IntConv => { score.intConvMatches = score.intConvMatches + 1; },
			TypeRelation.Convertible => { score.convMatches = score.convMatches + 1; },
			_ => {},
		};
	}
	return score;
}

// Compare inheritance penalties. -1 = inactive (sentinel).
// Lower penalty = more specific (better). Returns >0 if a is better.
function cmpInheritancePenalty(a: number, b: number): number {
	if (a === -1 && b === -1) return 0;
	if (a === -1) return -1; // a inactive, b has penalty → b is better
	if (b === -1) return 1;  // b inactive, a has penalty → a is better
	return b - a; // lower penalty is better, so b - a > 0 means a < b means a wins
}

// Standard-aligned priority comparison (9-step chain from reference signature matching).
// Returns >0 if a is better, <0 if b is better, 0 if ambiguous.
// candidateTypeA/B are the Function types for generic specialization (Phase 5).
// Pass null to skip steps 7-8.
export function cmpCandidates(a: CandidateScore, b: CandidateScore,
	candidateTypeA: Type, candidateTypeB: Type): number {
	// 1. Exact matches (highest priority)
	let result = a.exactMatches - b.exactMatches;
	if (result !== 0) return result;
	// 2. Generic matches
	result = a.genericMatches - b.genericMatches;
	if (result !== 0) return result;
	// 3. Subtype matches
	result = a.subtypeMatches - b.subtypeMatches;
	if (result !== 0) return result;
	// 4. Int conversion matches
	result = a.intConvMatches - b.intConvMatches;
	if (result !== 0) return result;
	// 5. Conversion matches
	result = a.convMatches - b.convMatches;
	if (result !== 0) return result;
	// 6. Inheritance penalty (lower = better)
	result = cmpInheritancePenalty(a.inheritancePenalty, b.inheritancePenalty);
	if (result !== 0) return result;
	// 7. checkGeneric — generic specialization (Phase 5, stubbed)
	if (candidateTypeA !== null && candidateTypeB !== null) {
		result = checkGenericSpecialization(candidateTypeA, candidateTypeB);
		if (result !== 0) return result;
		// 8. complexDisambiguation — genericness depth (Phase 5, stubbed)
		result = complexDisambiguation(candidateTypeA, candidateTypeB);
		if (result !== 0) return result;
	}
	// 9. Scope depth (higher = inner scope = preferred)
	result = a.calleeScope - b.calleeScope;
	return result;
}

// Generic specialization: cross-test formal types for specificity.
// f<T>(x: T[]) is more specific than f<T>(x: T) because T[] can match T generically
// but T cannot match T[].
// Returns >0 if A is more specific, <0 if B, 0 if equal/contradictory.
function checkGenericSpecialization(typeA: Type, typeB: Type): number {
	if (typeA === null || typeB === null) return 0;
	if (typeA.kind !== TypeKind.Function || typeB.kind !== TypeKind.Function) return 0;
	const lenA = typeA.typeChildren.length;
	const lenB = typeB.typeChildren.length;
	if (lenA !== lenB) return 0;
	let aWins = 0;
	let bWins = 0;
	let i = 0;
	while (i < lenA) {
		const pA = typeA.typeChildren[i];
		const pB = typeB.typeChildren[i];
		// Cross-test: can B's formal match A's as Generic?
		const bMatchesA = typeRelation(pA, pB);
		const aMatchesB = typeRelation(pB, pA);
		if (bMatchesA === TypeRelation.Generic && aMatchesB !== TypeRelation.Generic) {
			aWins = aWins + 1; // A is more specific (B is more general)
		} else if (aMatchesB === TypeRelation.Generic && bMatchesA !== TypeRelation.Generic) {
			bWins = bWins + 1; // B is more specific (A is more general)
		}
		i = i + 1;
	}
	if (aWins > 0 && bWins === 0) return 1;
	if (bWins > 0 && aWins === 0) return -1;
	return 0; // contradiction or equal
}

// Count generic nesting depth of a type (Standard reference implementation).
// Higher depth = more specific overload.
// GenericParam = 1, Container<T> = 1 + sumGeneric(T)
let sumGenericDepth = 0;
function sumGeneric(t: Type): number {
	if (t === null) return 0;
	if (t.kind === TypeKind.GenericParam || t.kind === TypeKind.Unknown) return 1;
	if (sumGenericDepth > 20) return 0;
	sumGenericDepth = sumGenericDepth + 1;
	let childSum = 0;
	let i = 0;
	while (i < t.typeChildren.length) {
		childSum = childSum + sumGeneric(t.typeChildren[i]);
		i = i + 1;
	}
	if (t.typeReturn !== null) {
		childSum = childSum + sumGeneric(t.typeReturn);
	}
	if (t.typeExtra !== null) {
		childSum = childSum + sumGeneric(t.typeExtra);
	}
	sumGenericDepth = sumGenericDepth - 1;
	if (childSum > 0) return childSum + 1;
	return 0;
}

// Complex disambiguation: per-parameter generic depth comparison.
// Higher sumGeneric = more specific overload.
// Per-parameter contradiction detection: if param i favors A but param j favors B → return 0.
// Returns >0 if A is more specific, <0 if B, 0 if equal/contradictory.
function complexDisambiguation(typeA: Type, typeB: Type): number {
	if (typeA === null || typeB === null) return 0;
	if (typeA.kind !== TypeKind.Function || typeB.kind !== TypeKind.Function) return 0;
	let aWins = 0;
	let bWins = 0;
	let i = 0;
	const len = typeA.typeChildren.length;
	while (i < len && i < typeB.typeChildren.length) {
		const gA = sumGeneric(typeA.typeChildren[i]);
		const gB = sumGeneric(typeB.typeChildren[i]);
		if (gA > gB) {
			aWins = aWins + 1;
		} else if (gB > gA) {
			bWins = bWins + 1;
		}
		i = i + 1;
	}
	// Contradiction: both have params where they're more specific → ambiguous
	if (aWins > 0 && bWins > 0) return 0;
	if (aWins > 0) return 1;
	if (bWins > 0) return -1;
	return 0;
}

// Resolve which overload index best matches argTypes.
// candidates: array of Function types (primary at [0], overloads at [1..n])
// scopeDepths: parallel array of scope depths per candidate (0 if same scope)
// Returns: index into candidates, -1 = no match, -2 = ambiguous
export function resolveOverloadIdx(candidates: Type[], argTypes: Type[],
	scopeDepths: number[]): number {
	let bestIdx = -1;
	let bestScore = emptyCandidateScore();
	let bestType: Type = null;
	let ambiguous = false;
	for (let i = 0; i < candidates.length; i += 1) {
		if (candidates[i].kind !== TypeKind.Function) continue;
		const score = scoreCandidatePriority(candidates[i].typeChildren, argTypes, getMinArity(candidates[i]));
		if (isNoMatch(score)) continue;
		// Set scope depth from parallel array
		if (i < scopeDepths.length) {
			score.calleeScope = scopeDepths[i];
		}
		if (bestIdx === -1) {
			bestIdx = i;
			bestScore = score;
			bestType = candidates[i];
			ambiguous = false;
		} else {
			const cmp = cmpCandidates(score, bestScore, candidates[i], bestType);
			if (cmp > 0) {
				bestIdx = i;
				bestScore = score;
				bestType = candidates[i];
				ambiguous = false;
			} else if (cmp === 0) {
				ambiguous = true;
			}
		}
	}
	if (ambiguous) return -2;
	return bestIdx;
}

// Find first mismatch position between a candidate's params and actual arg types.
// Returns 0-based position, or -1 if all match.
export function findFirstMismatch(paramTypes: Type[], argTypes: Type[], minArity: number): number {
	if (argTypes.length > paramTypes.length) return paramTypes.length; // extra arg
	if (argTypes.length < minArity) return argTypes.length; // missing required param
	for (let i = 0; i < argTypes.length; i += 1) {
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) return i;
	}
	return -1;
}

// ===== Tests =====
test "same kind" {
	assert isAssignable(numberType(), numberType());
	assert isAssignable(stringType(), stringType());
	assert isAssignable(booleanType(), booleanType());
}

test "different kind" {
	assert !isAssignable(numberType(), stringType());
	assert !isAssignable(stringType(), booleanType());
}

test "unknown compatible" {
	assert isAssignable(unknownType(), numberType());
	assert isAssignable(numberType(), unknownType());
}

test "numeric widening" {
	assert isAssignable(createPrimitive(TypeKind.Int32), numberType());
	assert isAssignable(createPrimitive(TypeKind.Float64), numberType());
}

test "null to nullable" {
	assert isAssignable(nullType(), createStruct("Foo", [], [], false));
	assert isAssignable(nullType(), createArray(numberType()));
	assert !isAssignable(nullType(), numberType());
}

test "same element" { assert isAssignable(createArray(numberType()), createArray(numberType())); }

test "different element" { assert !isAssignable(createArray(numberType()), createArray(stringType())); }

test "unknown element" { assert isAssignable(createArray(unknownType()), createArray(numberType())); }

test "same signature" {
	const f1 = createFunction([numberType()], ["a"], stringType());
	const f2 = createFunction([numberType()], ["b"], stringType());
	assert isAssignable(f1, f2);
}

test "different param count" {
	const f1 = createFunction([numberType()], ["a"], voidType());
	const f2 = createFunction([], [], voidType());
	assert !isAssignable(f1, f2);
}

test "covariant return" {
	const f1 = createFunction([], [], unknownType());
	const f2 = createFunction([], [], numberType());
	assert isAssignable(f1, f2);
}

test "nominal same name" {
	const o1 = createStruct("Type", ["kind"], [numberType()], false);
	const o2 = createStruct("Type", ["kind"], [unknownType()], false);
	assert isAssignable(o1, o2);
}

test "exact match" {
	const o1 = createStruct("A", ["x"], [numberType()], false);
	const o2 = createStruct("B", ["x"], [numberType()], false);
	assert isAssignable(o1, o2);
}

test "source has extra props" {
	const o1 = createStruct("A", ["x", "y"], [numberType(), stringType()], false);
	const o2 = createStruct("B", ["x"], [numberType()], false);
	assert isAssignable(o1, o2);
}

test "source missing prop" {
	const o1 = createStruct("A", ["x"], [numberType()], false);
	const o2 = createStruct("B", ["x", "y"], [numberType(), stringType()], false);
	assert !isAssignable(o1, o2);
}

test "exact match" {
	assert typeRelation(numberType(), numberType()) === TypeRelation.Exact;
	assert typeRelation(stringType(), stringType()) === TypeRelation.Exact;
}

test "no match" { assert typeRelation(numberType(), stringType()) === TypeRelation.None; }

test "unknown = generic" {
	assert typeRelation(numberType(), unknownType()) === TypeRelation.Generic;
	assert typeRelation(unknownType(), numberType()) === TypeRelation.Generic;
}

test "int conversion" { assert typeRelation(numberType(), createPrimitive(TypeKind.Int32)) === TypeRelation.IntConv; }

test "null to object" { assert typeRelation(createStruct("Foo", [], [], false), nullType()) === TypeRelation.Subtype; }

test "exact args" {
	const score = scoreCandidate([numberType(), stringType()], [numberType(), stringType()]);
	assert score === 12; // 6 + 6
}

test "arity mismatch" { assert scoreCandidate([numberType()], []) === -1; }

test "type mismatch" { assert scoreCandidate([numberType()], [stringType()]) === -1; }

test "mixed scoring" {
	const score = scoreCandidate([numberType(), numberType()], [numberType(), createPrimitive(TypeKind.Int32)]);
	assert score === 8; // 6 (exact) + 2 (intconv)
}

test "source union all match" {
	const u = createUnion([numberType(), stringType()]);
	assert !isAssignable(u, numberType());
}

test "target union has match" {
	const u = createUnion([numberType(), stringType()]);
	assert isAssignable(numberType(), u);
	assert isAssignable(stringType(), u);
	assert !isAssignable(booleanType(), u);
}

test "same result types" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(numberType(), stringType());
	assert isAssignable(r1, r2);
}

test "different ok type" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(stringType(), stringType());
	assert !isAssignable(r1, r2);
}

test "different err type" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(numberType(), numberType());
	assert !isAssignable(r1, r2);
}

test "unknown ok compatible" {
	const r1 = createResult(unknownType(), stringType());
	const r2 = createResult(numberType(), stringType());
	assert isAssignable(r1, r2);
}

test "same enum name" {
	const e1 = createEnum("Color", ["Red", "Green"], null as unknown as number[]);
	const e2 = createEnum("Color", ["Red", "Green"], null as unknown as number[]);
	assert isAssignable(e1, e2);
}

test "different enum name" {
	const e1 = createEnum("Color", ["Red"], null as unknown as number[]);
	const e2 = createEnum("Shape", ["Circle"], null as unknown as number[]);
	assert !isAssignable(e1, e2);
}

test "same ref inner" {
	const r1 = createRef(numberType());
	const r2 = createRef(numberType());
	assert isAssignable(r1, r2);
}

test "different ref inner" {
	const r1 = createRef(numberType());
	const r2 = createRef(stringType());
	assert !isAssignable(r1, r2);
}

test "same ptr inner" {
	const p1 = createPtr(numberType());
	const p2 = createPtr(numberType());
	assert isAssignable(p1, p2);
}

test "null to ref" { assert isAssignable(nullType(), createRef(numberType())); }

test "null to sized array" { assert isAssignable(nullType(), createSizedArray(numberType(), 4)); }

test "null to span" { assert isAssignable(nullType(), createSpan(numberType())); }

test "array to span" {
	const arr = createArray(numberType());
	const span = createSpan(numberType());
	assert isAssignable(arr, span);
	assert typeRelation(span, arr) === TypeRelation.Subtype;
}

test "sized array to span" {
	const sarr = createSizedArray(numberType(), 4);
	const span = createSpan(numberType());
	assert isAssignable(sarr, span);
	assert typeRelation(span, sarr) === TypeRelation.Subtype;
}

test "mismatched element to span" {
	const arr = createArray(stringType());
	const span = createSpan(numberType());
	assert !isAssignable(arr, span);
	assert typeRelation(span, arr) === TypeRelation.None;
}

test "null to ptr" { assert isAssignable(nullType(), createPtr(numberType())); }

test "same distinct name" {
	const d1 = createDistinct(numberType());
	d1.typeName = "UserId";
	const d2 = createDistinct(numberType());
	d2.typeName = "UserId";
	assert isAssignable(d1, d2);
}

test "different distinct name" {
	const d1 = createDistinct(numberType());
	d1.typeName = "UserId";
	const d2 = createDistinct(numberType());
	d2.typeName = "GroupId";
	assert !isAssignable(d1, d2);
}

test "enum exact" {
	const e1 = createEnum("Color", ["Red"], null as unknown as number[]);
	const e2 = createEnum("Color", ["Red"], null as unknown as number[]);
	assert typeRelation(e1, e2) === TypeRelation.Exact;
}

test "enum mismatch" {
	const e1 = createEnum("Color", ["Red"], null as unknown as number[]);
	const e2 = createEnum("Shape", ["Circle"], null as unknown as number[]);
	assert typeRelation(e1, e2) === TypeRelation.None;
}

test "result exact" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(numberType(), stringType());
	assert typeRelation(r1, r2) === TypeRelation.Exact;
}

test "result mismatch" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(stringType(), stringType());
	assert typeRelation(r1, r2) === TypeRelation.None;
}

test "array same element exact" { assert typeRelation(createArray(numberType()), createArray(numberType())) === TypeRelation.Exact; }

test "array different element none" { assert typeRelation(createArray(numberType()), createArray(stringType())) === TypeRelation.None; }

test "ref same inner exact" { assert typeRelation(createRef(numberType()), createRef(numberType())) === TypeRelation.Exact; }

test "ref different inner none" { assert typeRelation(createRef(numberType()), createRef(stringType())) === TypeRelation.None; }

test "ptr same inner exact" { assert typeRelation(createPtr(numberType()), createPtr(numberType())) === TypeRelation.Exact; }

test "ptr different inner none" { assert typeRelation(createPtr(numberType()), createPtr(stringType())) === TypeRelation.None; }

test "from literal" {
	assert typeRelation(createPrimitive(TypeKind.Int32), numberType()) === TypeRelation.FromLiteral;
	assert typeRelation(createPrimitive(TypeKind.Float64), numberType()) === TypeRelation.FromLiteral;
}

test "generic param" {
	const gp = createGenericParam("T");
	assert typeRelation(gp, numberType()) === TypeRelation.Generic;
	assert typeRelation(numberType(), gp) === TypeRelation.Generic;
}

test "exact beats subtype-sum" {
	// a: 1 exact + 0 subtype; b: 0 exact + 3 subtype
	// Priority: exact wins regardless of subtype count
	const a = emptyCandidateScore();
	a.exactMatches = 1;
	const b = emptyCandidateScore();
	b.subtypeMatches = 3;
	const nullT = null;
	assert cmpCandidates(a, b, nullT, nullT) > 0;
}

test "FromLiteral weight intConvMatches += 256" {
	// formal=Int32, actual=Number → FromLiteral (number literal to sized param)
	const params = [createPrimitive(TypeKind.Int32)];
	const args = [numberType()];
	const score = scoreCandidatePriority(params, args, params.length);
	assert !isNoMatch(score);
	// FromLiteral maps to intConvMatches += 256
	assert score.intConvMatches === 256;
	assert score.exactMatches === 0;
}

test "ambiguity: equal scores" {
	// Two identical candidates → cmp returns 0
	const a = emptyCandidateScore();
	a.exactMatches = 2;
	const b = emptyCandidateScore();
	b.exactMatches = 2;
	const nullT = null;
	assert cmpCandidates(a, b, nullT, nullT) === 0;
}

test "inheritance penalty: lower wins" {
	const a = emptyCandidateScore();
	a.exactMatches = 1;
	a.inheritancePenalty = 1; // direct parent
	const b = emptyCandidateScore();
	b.exactMatches = 1;
	b.inheritancePenalty = 3; // grandgrandparent
	const nullT = null;
	// a has lower penalty → a is better → result > 0
	assert cmpCandidates(a, b, nullT, nullT) > 0;
}

test "scope depth: inner wins" {
	const a = emptyCandidateScore();
	a.exactMatches = 1;
	a.calleeScope = 2;
	const b = emptyCandidateScore();
	b.exactMatches = 1;
	b.calleeScope = 0;
	const nullT = null;
	// a is inner (higher scope) → a wins → result > 0
	assert cmpCandidates(a, b, nullT, nullT) > 0;
}

test "single candidate matches" {
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const candidates = [fn1];
	const argTypes = [numberType()];
	const depths = [0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === 0;
}

test "picks best of two" {
	// fn1(number) vs fn2(string); call with number → fn1 wins (idx 0)
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const fn2 = createFunction([stringType()], ["b"], stringType());
	const candidates = [fn1, fn2];
	const argTypes = [numberType()];
	const depths = [0, 0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === 0;
}

test "picks second overload" {
	// fn1(number) vs fn2(string); call with string → fn2 wins (idx 1)
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const fn2 = createFunction([stringType()], ["b"], stringType());
	const candidates = [fn1, fn2];
	const argTypes = [stringType()];
	const depths = [0, 0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === 1;
}

test "no match returns -1" {
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const candidates = [fn1];
	const argTypes = [stringType()];
	const depths = [0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === -1;
}

test "ambiguous returns -2" {
	// Two identical-signature candidates → ambiguous
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const fn2 = createFunction([numberType()], ["b"], numberType());
	const candidates = [fn1, fn2];
	const argTypes = [numberType()];
	const depths = [0, 0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === -2;
}

test "all match" { assert findFirstMismatch([numberType()], [numberType()], 1) === -1; }

test "first param mismatch" { assert findFirstMismatch([numberType()], [stringType()], 1) === 0; }

test "second param mismatch" { assert findFirstMismatch([numberType(), stringType()], [numberType(), numberType()], 2) === 1; }

test "arity mismatch too many args" { assert findFirstMismatch([numberType()], [numberType(), stringType()], 1) === 1; }

test "arity mismatch too few args" { assert findFirstMismatch([numberType(), stringType()], [numberType()], 2) === 1; }

test "complexDisambiguation deeper type wins" {
	// f(T[]) vs f(T) — array param has deeper generic nesting
	const gp = createGenericParam("T");
	const arrGp = createArray(gp);
	const fnDeep = createFunction([arrGp], ["x"], stringType());
	const fnShallow = createFunction([gp], ["x"], stringType());
	const a = emptyCandidateScore();
	a.genericMatches = 1;
	const b = emptyCandidateScore();
	b.genericMatches = 1;
	const nullT = null;
	// step 7 (checkGenericSpecialization) + step 8 (complexDisambiguation) should
	// prefer deeper nesting. With equal genericMatches, cmpCandidates goes to step 7+8.
	const cmp = cmpCandidates(a, b, fnDeep, fnShallow);
	assert cmp > 0;
}

test "complexDisambiguation per-param contradiction returns 0" {
	// f<T,U>(x: T[], y: U) vs f<T,U>(x: T, y: U[])
	// param 0 favors A (deeper), param 1 favors B (deeper) → contradiction → 0
	const gp1 = createGenericParam("T");
	const gp2 = createGenericParam("U");
	const arrGp1 = createArray(gp1);
	const arrGp2 = createArray(gp2);
	const fnA = createFunction([arrGp1, gp2], ["x", "y"], stringType());
	const fnB = createFunction([gp1, arrGp2], ["x", "y"], stringType());
	const a = emptyCandidateScore();
	a.genericMatches = 2;
	const b = emptyCandidateScore();
	b.genericMatches = 2;
	const cmp = cmpCandidates(a, b, fnA, fnB);
	assert cmp === 0;
}
