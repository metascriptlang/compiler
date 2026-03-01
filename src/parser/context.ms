// Parser Context - Shared parser state and helpers
// Pattern: ~/projects/metascript/src/parser/context.zig

import { Token, TokenKind } from "../lexer/token";

// ===== Parser State =====

export interface ParserState {
	tokens: Token[];
	position: number;
	errors: string[];
	panicMode: boolean;
}

export function createState(tokens: Token[]): ParserState {
	return { tokens, position: 0, errors: [], panicMode: false };
}

export function current(state: ParserState): Token {
	return state.tokens[state.position];
}

export function advance(state: ParserState): Token {
	const token = current(state);
	state.position += 1;
	return token;
}

export function isAtEnd(state: ParserState): boolean {
	return current(state).kind === TokenKind.Eof;
}

// ===== Lookahead =====

export function peek(state: ParserState, offset: number): Token {
	const idx = state.position + offset;
	if (idx < state.tokens.length) {
		return state.tokens[idx];
	}
	return state.tokens[state.tokens.length - 1];
}

// ===== Expect Helper =====

export function expect(state: ParserState, kind: TokenKind, msg: string): Result<Token, string> {
	const token = current(state);
	if (token.kind !== kind) {
		return Result.err(`${msg} at line ${token.line.toString()}`);
	}
	advance(state);
	return Result.ok(token);
}

// ===== Error Recovery =====
// Pattern: ~/projects/metascript/src/parser/parser.zig reportError + synchronize

// Record a parse error. In panic mode, suppress cascading errors.
export function addError(state: ParserState, msg: string): void {
	if (!state.panicMode) {
		state.errors.push(msg);
		state.panicMode = true;
	}
}

// Skip tokens until a statement boundary to resume parsing after an error.
// Pattern: Zig parser.zig:7504-7546
export function synchronize(state: ParserState): void {
	state.panicMode = false;
	while (!isAtEnd(state)) {
		const kind = current(state).kind;
		// Statement-starting keywords — resume here
		if (kind === TokenKind.Const || kind === TokenKind.Let ||
			kind === TokenKind.If || kind === TokenKind.While ||
			kind === TokenKind.For || kind === TokenKind.Function ||
			kind === TokenKind.Return || kind === TokenKind.Import ||
			kind === TokenKind.Export || kind === TokenKind.Class ||
			kind === TokenKind.Enum || kind === TokenKind.Interface ||
			kind === TokenKind.Type || kind === TokenKind.Throw ||
			kind === TokenKind.Try || kind === TokenKind.Match ||
			kind === TokenKind.Switch || kind === TokenKind.Defer ||
			kind === TokenKind.At || kind === TokenKind.Break ||
			kind === TokenKind.Continue || kind === TokenKind.Async) {
			return;
		}
		// Closing brace — consume it and resume
		if (kind === TokenKind.RBrace) {
			advance(state);
			return;
		}
		advance(state);
		// Past semicolon — resume on next token
		if (kind === TokenKind.Semicolon) { return; }
	}
}

// ===== Common Helpers =====

// Consume optional trailing semicolon
export function consumeSemicolon(state: ParserState): void {
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
}

// Skip balanced delimiter pairs: parens, braces, brackets.
// Consumes the opening token and everything through the matching close.
// Caller must ensure current token is `open` before calling.
export function skipBalanced(state: ParserState, open: TokenKind, close: TokenKind): void {
	if (isAtEnd(state) || current(state).kind !== open) { return; }
	advance(state);
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind === open) { depth += 1; }
		if (current(state).kind === close) { depth -= 1; }
		if (depth > 0) { advance(state); }
	}
	if (!isAtEnd(state) && current(state).kind === close) { advance(state); }
}

// Skip balanced <...> generic type parameters (e.g., class Foo<T> or extends Bar<T>)
// Handles >> and >>> for nested generics like Result<Array<number>>
export function skipGenericParams(state: ParserState): void {
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) { return; }
	advance(state);
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind === TokenKind.Lt) { depth += 1; }
		if (current(state).kind === TokenKind.Gt) { depth -= 1; }
		if (current(state).kind === TokenKind.GtGt) { depth -= 2; }
		if (current(state).kind === TokenKind.GtGtGt) { depth -= 3; }
		advance(state);
	}
}


// Capture generic param names: <T, U> → "T,U", no generics → ""
// Same depth-tracking as skipGenericParams but returns names instead of discarding.
export function captureGenericParams(state: ParserState): string {
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) return "";
	advance(state); // consume <
	let names = "";
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind === TokenKind.Ident && depth === 1) {
			if (names !== "") { names = names + ","; }
			names = names + current(state).value;
			advance(state);
			// Check for constraint: T extends Type
			if (!isAtEnd(state) && current(state).kind === TokenKind.Extends && depth === 1) {
				advance(state); // skip 'extends'
				// Capture constraint type name
				if (!isAtEnd(state) && current(state).kind === TokenKind.Ident) {
					names = names + ":" + current(state).value;
					advance(state);
				}
			}
			continue;
		}
		if (current(state).kind === TokenKind.Lt) { depth += 1; }
		if (current(state).kind === TokenKind.Gt) { depth -= 1; }
		if (current(state).kind === TokenKind.GtGt) { depth -= 2; }
		if (current(state).kind === TokenKind.GtGtGt) { depth -= 3; }
		advance(state);
	}
	return names;
}

// Lookahead: is this '<' the start of generic type args followed by '('?
// Reference: parser.zig:4183 isGenericCallAhead()
// Scans ahead for balanced <...> then checks for '(' immediately after.
// Does NOT consume tokens — only peeks.
export function isGenericCallAhead(state: ParserState): boolean {
	// Current token should be '<'
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) return false;
	let angleDepth = 1;
	let braceDepth = 0;
	let bracketDepth = 0;
	let parenDepth = 0;
	for (let pos = 1; pos < 100; pos += 1) {
		const tok = peek(state, pos);
		if (tok.kind === TokenKind.Eof) return false;
		// Track nested delimiters
		if (tok.kind === TokenKind.LBrace) { braceDepth += 1; }
		if (tok.kind === TokenKind.RBrace) { braceDepth -= 1; if (braceDepth < 0) return false; }
		if (tok.kind === TokenKind.LBracket) { bracketDepth += 1; }
		if (tok.kind === TokenKind.RBracket) { bracketDepth -= 1; if (bracketDepth < 0) return false; }
		if (tok.kind === TokenKind.LParen) { parenDepth += 1; }
		if (tok.kind === TokenKind.RParen) { parenDepth -= 1; if (parenDepth < 0) return false; }
		// Only count angle brackets at top level (not inside {} [] ())
		if (braceDepth === 0 && bracketDepth === 0 && parenDepth === 0) {
			if (tok.kind === TokenKind.Lt) { angleDepth += 1; }
			if (tok.kind === TokenKind.Gt) { angleDepth -= 1; }
			if (tok.kind === TokenKind.GtGt) { angleDepth -= 2; }
			if (tok.kind === TokenKind.GtGtGt) { angleDepth -= 3; }
			if (angleDepth <= 0) {
				// Found matching '>' — check if next token is '('
				const next = peek(state, pos + 1);
				return next.kind === TokenKind.LParen;
			}
		}
		// Bail on tokens that can't appear in type args
		if (tok.kind === TokenKind.Semicolon) return false;
		if (tok.kind === TokenKind.Assign) return false;
	}
	return false;
}

// Capture generic type args at call site: <number, string> → "number,string"
// Unlike captureGenericParams (which captures parameter NAMES like T, U),
// this captures full type expressions (identifiers, keywords, nested generics).
export function captureGenericTypeArgs(state: ParserState): string {
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) return "";
	advance(state); // consume <
	// Two-pass: first collect token values with separators, then split.
	// Avoid `let str = ""; str = "";` — DRC generates ms_decref on struct msString.
	const tokens: string[] = [];
	const depths: number[] = [];
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		const tok = current(state);
		if (tok.kind === TokenKind.Lt) { depth += 1; }
		else if (tok.kind === TokenKind.Gt) { depth -= 1; }
		else if (tok.kind === TokenKind.GtGt) { depth -= 2; }
		else if (tok.kind === TokenKind.GtGtGt) { depth -= 3; }
		if (depth > 0) {
			tokens.push(tok.value);
			depths.push(depth);
		}
		advance(state);
	}
	// Build comma-separated type args in single pass.
	// Depth-1 commas are arg separators → emit our ",".
	// NEVER reset a string variable to "" — DRC generates ms_decref(msString) → void* mismatch.
	let result = "";
	let afterSep = false;
	let argHasTokens = false;
	for (let i = 0; i < tokens.length; i += 1) {
		if (tokens[i] === "," && depths[i] === 1) {
			afterSep = true;
			argHasTokens = false;
		} else {
			if (afterSep) {
				result = result + ",";
				afterSep = false;
			}
			if (argHasTokens && tokens[i] !== ",") {
				result = result + " ";
			}
			result = result + tokens[i];
			argHasTokens = true;
		}
	}
	return result;
}

// ===== Pattern Helpers =====

// Skip a destructuring pattern: { ... } or [ ... ] including nesting.
// Used when we need to consume but not store the pattern (param lists, for-of bindings).
export function skipDestructurePattern(state: ParserState): void {
	let depth = 0;
	while (!isAtEnd(state)) {
		if (current(state).kind === TokenKind.LBrace || current(state).kind === TokenKind.LBracket) {
			depth += 1;
		}
		if (current(state).kind === TokenKind.RBrace || current(state).kind === TokenKind.RBracket) {
			depth -= 1;
			advance(state);
			if (depth === 0) { return; }
			continue;
		}
		advance(state);
	}
}

// ===== Explicit Type Args Side-Channel =====
// Parser stores explicit type args (e.g., foo<number>(x)) keyed by call site location.
// Monomorphize reads this. Checker is not involved — callee name stays clean.
// Uses interface + factory function (same pattern as NodeCache / CtxCache).

interface TypeArgEntry {
	key: string;
	val: string;
}

interface TypeArgStore {
	items: TypeArgEntry[];
}

function createTypeArgStore(): TypeArgStore {
	const items: TypeArgEntry[] = [];
	return { items };
}

let _typeArgStore: TypeArgStore = createTypeArgStore();

export function resetExplicitTypeArgs(): void {
	_typeArgStore = createTypeArgStore();
}

export function addExplicitTypeArg(line: number, col: number, typeArgStr: string): void {
	const key = line.toString() + ":" + col.toString();
	const entry: TypeArgEntry = { key, val: typeArgStr };
	_typeArgStore.items.push(entry);
}

export function getExplicitTypeArg(line: number, col: number): string {
	const key = line.toString() + ":" + col.toString();
	for (let i = 0; i < _typeArgStore.items.length; i += 1) {
		if (_typeArgStore.items[i].key === key) return _typeArgStore.items[i].val;
	}
	return "";
}

// ===== Generic Declaration Side-Channel =====
// Parser stores generic params for interface/class declarations (e.g., interface Box<T>).
// Checker reads this to create GenericParam types for field resolution.
// Same pattern as TypeArgStore above.

interface GenericDeclEntry {
	key: string;        // interface/class name
	val: string;        // comma-joined generic param names ("T,U")
	fieldNames: string; // "|"-joined field names ("value|count"), empty for functions
	fieldTypes: string; // "|"-joined field type annotations ("T|number"), empty for functions
}

interface GenericDeclStore {
	items: GenericDeclEntry[];
}

function createGenericDeclStore(): GenericDeclStore {
	const items: GenericDeclEntry[] = [];
	return { items };
}

let _genericDeclStore: GenericDeclStore = createGenericDeclStore();

export function resetGenericDeclStore(): void {
	_genericDeclStore = createGenericDeclStore();
}

export function addGenericDecl(name: string, genericParams: string): void {
	const entry: GenericDeclEntry = { key: name, val: genericParams, fieldNames: "", fieldTypes: "" };
	_genericDeclStore.items.push(entry);
}

// Update an existing GenericDeclEntry with field info (called after parsing interface body)
export function updateGenericDeclFields(name: string, fieldNames: string, fieldTypes: string): void {
	for (let i = 0; i < _genericDeclStore.items.length; i += 1) {
		if (_genericDeclStore.items[i].key === name) {
			_genericDeclStore.items[i].fieldNames = fieldNames;
			_genericDeclStore.items[i].fieldTypes = fieldTypes;
			return;
		}
	}
}

export function getGenericDecl(name: string): string {
	for (let i = 0; i < _genericDeclStore.items.length; i += 1) {
		if (_genericDeclStore.items[i].key === name) return _genericDeclStore.items[i].val;
	}
	return "";
}

// Get "|"-joined field names for a generic interface/class
export function getGenericDeclFieldNames(name: string): string {
	for (let i = 0; i < _genericDeclStore.items.length; i += 1) {
		if (_genericDeclStore.items[i].key === name) return _genericDeclStore.items[i].fieldNames;
	}
	return "";
}

// Get "|"-joined field type annotations for a generic interface/class
export function getGenericDeclFieldTypes(name: string): string {
	for (let i = 0; i < _genericDeclStore.items.length; i += 1) {
		if (_genericDeclStore.items[i].key === name) return _genericDeclStore.items[i].fieldTypes;
	}
	return "";
}

// ===== Generic Type Instantiation Registry =====
// Checker records instantiations (e.g., Box<number>) here.
// Codegen reads this to emit concrete struct definitions.
// DRC-safe: string fields only, module-level side-channel.
// Lives in parser/context to avoid heavy checker imports in codegen (DRC #22/#26).
// Uses GenericDeclEntry[] as backing store (reuses existing interface to avoid new union members).

// Store instantiation: baseName + typeArgKey + mangledName + fieldNamesJoined + fieldTypesJoined
// Encoded in GenericDeclEntry as: key=mangledName, val=baseName+"|"+typeArgKey, fieldNames=..., fieldTypes=...

interface GenericTypeInstStore {
	keys: string[];       // mangledName entries
	baseNames: string[];
	typeArgKeys: string[];
	fieldNames: string[];  // "|"-joined field names per entry
	fieldTypes: string[];  // "|"-joined field types per entry
}

function createGenericTypeInstStore(): GenericTypeInstStore {
	return { keys: [], baseNames: [], typeArgKeys: [], fieldNames: [], fieldTypes: [] };
}

let _genericTypeInstStore: GenericTypeInstStore = createGenericTypeInstStore();

export function resetGenericTypeInsts(): void {
	_genericTypeInstStore = createGenericTypeInstStore();
}

export function addGenericTypeInst(baseName: string, typeArgKey: string, mangledName: string, fieldNamesJoined: string, fieldTypesJoined: string): void {
	// Dedup: skip if same baseName + typeArgKey already exists
	for (let i = 0; i < _genericTypeInstStore.keys.length; i += 1) {
		if (_genericTypeInstStore.baseNames[i] === baseName && _genericTypeInstStore.typeArgKeys[i] === typeArgKey) return;
	}
	_genericTypeInstStore.keys.push(mangledName);
	_genericTypeInstStore.baseNames.push(baseName);
	_genericTypeInstStore.typeArgKeys.push(typeArgKey);
	_genericTypeInstStore.fieldNames.push(fieldNamesJoined);
	_genericTypeInstStore.fieldTypes.push(fieldTypesJoined);
}

export function getGenericTypeInstCount(): number {
	return _genericTypeInstStore.keys.length;
}

export function getGenericTypeInstMangledName(idx: number): string {
	return _genericTypeInstStore.keys[idx];
}

export function getGenericTypeInstBaseName(idx: number): string {
	return _genericTypeInstStore.baseNames[idx];
}

export function getGenericTypeInstTypeArgKey(idx: number): string {
	return _genericTypeInstStore.typeArgKeys[idx];
}

export function getGenericTypeInstFieldNames(idx: number): string {
	return _genericTypeInstStore.fieldNames[idx];
}

export function getGenericTypeInstFieldTypes(idx: number): string {
	return _genericTypeInstStore.fieldTypes[idx];
}

export function findGenericTypeInstIdx(baseName: string, typeArgKey: string): number {
	for (let i = 0; i < _genericTypeInstStore.keys.length; i += 1) {
		if (_genericTypeInstStore.baseNames[i] === baseName && _genericTypeInstStore.typeArgKeys[i] === typeArgKey) return i;
	}
	return -1;
}

// Count pipe-separated segments in a string
function pipeCount(s: string): number {
	if (s === "") return 0;
	let count = 1;
	for (let i = 0; i < s.length; i += 1) {
		const ch = s[i];
		if (ch === "|") count += 1;
	}
	return count;
}

// Get the nth pipe-separated segment (0-based)
function pipeAt(s: string, idx: number): string {
	let count = 0;
	let start = 0;
	for (let i = 0; i < s.length; i += 1) {
		const ch = s[i];
		if (ch === "|") {
			if (count === idx) {
				let result = "";
				for (let j = start; j < i; j += 1) { result = result + s[j]; }
				return result;
			}
			count += 1;
			start = i + 1;
		}
	}
	if (count === idx) {
		let result = "";
		for (let j = start; j < s.length; j += 1) { result = result + s[j]; }
		return result;
	}
	return "";
}

export function getGenericTypeInstFieldCount(instIdx: number): number {
	return pipeCount(_genericTypeInstStore.fieldNames[instIdx]);
}

export function getGenericTypeInstFieldNameAt(instIdx: number, fieldIdx: number): string {
	return pipeAt(_genericTypeInstStore.fieldNames[instIdx], fieldIdx);
}

export function getGenericTypeInstFieldTypeAt(instIdx: number, fieldIdx: number): string {
	return pipeAt(_genericTypeInstStore.fieldTypes[instIdx], fieldIdx);
}

// ===== Default Parameter Side-Channel =====
// Parser stores default value source text for function parameters with defaults.
// Checker reads this to know minArity and to re-parse defaults at call sites.
// DRC-safe: string/number fields only, module-level side-channel.
// Same SoA pattern as GenericTypeInstStore.

interface DefaultParamStore {
	fnKeys: string[];       // function name (e.g., "foo")
	paramIdxs: number[];    // 0-based parameter index
	defaultTexts: string[]; // reconstructed source text (e.g., "5", "\"hello\"")
}

function createDefaultParamStore(): DefaultParamStore {
	return { fnKeys: [], paramIdxs: [], defaultTexts: [] };
}

let _defaultParamStore: DefaultParamStore = createDefaultParamStore();

export function resetDefaultParamStore(): void {
	_defaultParamStore = createDefaultParamStore();
}

export function addDefaultParam(fnKey: string, paramIdx: number, text: string): void {
	_defaultParamStore.fnKeys.push(fnKey);
	_defaultParamStore.paramIdxs.push(paramIdx);
	_defaultParamStore.defaultTexts.push(text);
}

export function getDefaultText(fnKey: string, paramIdx: number): string {
	let i = 0;
	while (i < _defaultParamStore.fnKeys.length) {
		if (_defaultParamStore.fnKeys[i] === fnKey && _defaultParamStore.paramIdxs[i] === paramIdx) {
			return _defaultParamStore.defaultTexts[i];
		}
		i = i + 1;
	}
	return "";
}

export function getDefaultCount(fnKey: string, totalParams: number): number {
	let count = 0;
	let i = 0;
	while (i < _defaultParamStore.fnKeys.length) {
		if (_defaultParamStore.fnKeys[i] === fnKey && _defaultParamStore.paramIdxs[i] < totalParams) {
			count = count + 1;
		}
		i = i + 1;
	}
	return count;
}
