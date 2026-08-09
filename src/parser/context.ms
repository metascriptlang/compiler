// Parser Context - Shared parser state and helpers
// Pattern: ~/projects/metascript/src/parser/context.zig

import { Token, TokenKind } from "../lexer/token";
import { Node, NodeKind, CallExprData, IdentifierData, MemberExprData } from "../ast/node";
import { DefineTable, createDefineTable } from "../compiler/defines";
// Local copy of util.ms:isIdentLike to avoid circular import with util.ms.
// Must stay in sync with the canonical version in util.ms.
function isIdentLikeToken(token: Token): boolean {
	const k = token.kind;
	if (k === TokenKind.Ident) { return true; }
	return (k as number) >= (TokenKind.Abstract as number) && k !== TokenKind.Comment && k !== TokenKind.Eof && (k as number) < (TokenKind.JsxTagStart as number);
}

// ===== Parser State =====

export class ParserState {
	tokens: Token[];
	position: number;
	errors: string[];
	panicMode: boolean;
	pendingComments: Token[]; // Added for comment preservation
	pendingTypeArg: string; // Captured <T> type arg waiting to be consumed by next CallExpr
	// Restricted production (like JS's NoIn): >0 while parsing a match-case
	// `when` guard, where a bare `ident =>` must NOT start an arrow function —
	// that `=>` belongs to the match arm. Parenthesized arrows still parse.
	noBareArrow: number;
}

export function createState(tokens: Token[]): ParserState {
	return { tokens, position: 0, errors: [], panicMode: false, pendingComments: [], pendingTypeArg: "", noBareArrow: 0 };
}

// Stamp a node's end position from the last consumed token (position - 1).
// Call AFTER the node is fully parsed. Safe to call multiple times.
export function stampEnd(state: ParserState, node: Node): void {
	if (node === null || node.location === null) return;
	const prevIdx = state.position - 1;
	if (prevIdx < 0 || prevIdx >= state.tokens.length) return;
	const prev = state.tokens[prevIdx];
	node.location.endLine = prev.line as int32;
	node.location.endColumn = (prev.column + prev.value.length) as int32;
}

// Internal helper to get the raw token at current position (including comments)
function rawCurrent(state: ParserState): Token {
	if (state.position >= state.tokens.length) return { kind: TokenKind.Eof, value: "", line: 0, column: 0, rawValue: "" };
	return state.tokens[state.position];
}

// Public helper to get the next non-comment token.
// Transparently skips comments so parser logic remains focused on semantics.
export function current(state: ParserState): Token {
	let pos = state.position;
	while (pos < state.tokens.length && state.tokens[pos].kind === TokenKind.Comment) {
		pos += 1;
	}
	if (pos < state.tokens.length) return state.tokens[pos];
	if (state.tokens.length === 0) return { kind: TokenKind.Eof, value: "", line: 0, column: 0, rawValue: "" };
	return state.tokens[state.tokens.length - 1]; // Safe EOF fallback
}

export function advance(state: ParserState): Token {
	// Skip and collect comment tokens into the side-channel.
	// Comments are attached to the NEXT non-comment token (leading comments).
	while (state.position < state.tokens.length && state.tokens[state.position].kind === TokenKind.Comment) {
		state.pendingComments.push(state.tokens[state.position]);
		state.position += 1;
	}

	if (state.position >= state.tokens.length) return { kind: TokenKind.Eof, value: "", line: 0, column: 0, rawValue: "" };
	const token = state.tokens[state.position];
	if (token.kind !== TokenKind.Eof) {
		state.position += 1;
	}
	return token;
}

// Helper to take and clear pending comments (the "Harvest")
// Also collects any comment tokens at the current position that haven't been
// advanced over yet. This ensures comments immediately before a construct
// are attached to it (e.g., leading comments before a function parameter).
export function takePendingComments(state: ParserState): Token[] {
	while (state.position < state.tokens.length && state.tokens[state.position].kind === TokenKind.Comment) {
		state.pendingComments.push(state.tokens[state.position]);
		state.position += 1;
	}
	const comments = state.pendingComments;
	state.pendingComments = [];
	return comments;
}

export function isAtEnd(state: ParserState): boolean {
	let pos = state.position;
	// Skip comments to see if we are genuinely at EOF
	while (pos < state.tokens.length && state.tokens[pos].kind === TokenKind.Comment) {
		pos += 1;
	}
	if (pos >= state.tokens.length) return true;
	return state.tokens[pos].kind === TokenKind.Eof;
}

// ===== Lookahead =====

export function peek(state: ParserState, offset: number): Token {
	let pos = state.position;
	let count = 0;
	while (pos < state.tokens.length) {
		if (state.tokens[pos].kind !== TokenKind.Comment) {
			if (count === offset) return state.tokens[pos];
			count += 1;
		}
		pos += 1;
	}
	if (state.tokens.length === 0) return { kind: TokenKind.Eof, value: "", line: 0, column: 0, rawValue: "" };
	return state.tokens[state.tokens.length - 1]; // EOF
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

// Collect token text from a raw index range, skipping Comment tokens.
// Used by type annotation capture, as-type, sizeof, alias, default value reconstruction.
export function collectTokenText(state: ParserState, start: number, end: number): string {
	let text = "";
	for (let i = start; i < end; i += 1) {
		const tok = state.tokens[i];
		if (tok.kind === TokenKind.Comment) continue;
		// Smart spacing: reproduce original token adjacency for type annotations.
		// No space around brackets [], angles <>, parens (), commas, colons, dots.
		if (text !== "") {
			const lastCh = text.byteAt(text.byteLength - 1);
			const v = tok.value;
			const noSpaceBefore = v === "[" || v === "]" || v === ">" || v === ">>" || v === ">>>"
				|| v === ")" || v === "," || v === "." || v === "?" || v === ":"
				|| v === "<" || v === "(";
			const noSpaceAfter = lastCh === "[".code || lastCh === "<".code || lastCh === "(".code
				|| lastCh === ".".code || lastCh === "?".code;
			if (!noSpaceBefore && !noSpaceAfter) text = text + " ";
		}
		// Preserve quotes on string literal tokens so resolveAnnotation can
		// distinguish string literal union members ("r8unorm") from type names.
		if (tok.kind === TokenKind.String) {
			text = text + "\"" + tok.value + "\"";
		} else {
			text = text + tok.value;
		}
	}
	return text;
}

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
		if (isIdentLikeToken(current(state)) && depth === 1) {
			if (names !== "") { names = `${names},`; }
			names = `${names}${current(state).value}`;
			advance(state);
			// Check for constraint: T extends Type
			if (!isAtEnd(state) && current(state).kind === TokenKind.Extends && depth === 1) {
				advance(state); // skip 'extends'
				// Capture constraint type name
				if (!isAtEnd(state) && isIdentLikeToken(current(state))) {
					names = `${names}:${current(state).value}`;
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
	// Avoid `let str = ""; str = "";` — DRC generates msDecref on struct msString.
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
	// NEVER reset a string variable to "" — DRC generates msDecref(msString) → void* mismatch.
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
	const key = `${line}:${col}`;
	const entry: TypeArgEntry = { key, val: typeArgStr };
	_typeArgStore.items.push(entry);
}

export function getExplicitTypeArg(line: number, col: number): string {
	const key = `${line}:${col}`;
	for (const item of _typeArgStore.items) {
		if (item.key === key) return item.val;
	}
	return "";
}

// Find explicit type arg for a call node. The parser stores type args at the '<' token position,
// but CallExpr node location is at '('. Compute '<' position from callee name.
export function findCallTypeArg(node: Node): string {
	// Primary: read from AST-resident field (set by parser, survives C compilation)
	if (node.typeArg !== null && node.typeArg !== "") return node.typeArg;
	// Fallback: legacy side-channel lookup (for nodes created without pendingTypeArg, e.g. NewExpr)
	const cd = node.data as CallExprData;
	let result = getExplicitTypeArg(node.location.line, node.location.column);
	if (result !== "") return result;
	if (cd.callee !== null && cd.callee.kind === NodeKind.Identifier) {
		const calleeName = (cd.callee.data as IdentifierData).name;
		const ltCol = cd.callee.location.column + calleeName.length;
		result = getExplicitTypeArg(cd.callee.location.line, ltCol);
		if (result !== "") return result;
	}
	if (cd.callee !== null && cd.callee.kind === NodeKind.MemberExpr) {
		const me = cd.callee.data as MemberExprData;
		const propLen = me.property.length;
		const ltCol1 = cd.callee.location.column + propLen;
		result = getExplicitTypeArg(cd.callee.location.line, ltCol1);
		if (result !== "") return result;
		result = getExplicitTypeArg(cd.callee.location.line, ltCol1 + 1);
		if (result !== "") return result;
		if (me.object !== null && me.object.kind === NodeKind.Identifier) {
			const objName = (me.object.data as IdentifierData).name;
			const propCol = me.object.location.column + objName.length + 1;
			const ltCol2 = propCol + propLen;
			result = getExplicitTypeArg(cd.callee.location.line, ltCol2);
			if (result !== "") return result;
		}
	}
	return "";
}

export function consumePendingTypeArg(state: ParserState): string {
	const ta = state.pendingTypeArg;
	state.pendingTypeArg = "";
	return ta;
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
	let i = 0;
	while (i < _genericDeclStore.items.length) {
		if (_genericDeclStore.items[i].key === name) {
			_genericDeclStore.items[i].fieldNames = fieldNames;
			_genericDeclStore.items[i].fieldTypes = fieldTypes;
			return;
		}
		i = i + 1;
	}
}

export function getGenericDecl(name: string): string {
	let i = 0;
	while (i < _genericDeclStore.items.length) {
		if (_genericDeclStore.items[i].key === name) return _genericDeclStore.items[i].val;
		i = i + 1;
	}
	// Built-in generic types — never parsed, so never registered via
	// addGenericDecl. Hardcode their param names so instantiateGenericBody
	// can populate typeReturn for them. Without this, peelToStructOrUnion
	// falls back to the un-substituted typeExtra and downstream narrowing
	// leaks GenericParam (Bug 16). The alternative — substituting typeExtra
	// inside substituteType — costs ~20× compile time on self-host and is
	// rejected.
	return match (name) {
		"Result" => "T,E",
		"Promise" => "T",
		"Iterator" => "T",
		"Arc" => "T",
		_ => "",
	};
}

// Get "|"-joined field names for a generic interface/class
export function getGenericDeclFieldNames(name: string): string {
	let i = 0;
	while (i < _genericDeclStore.items.length) {
		if (_genericDeclStore.items[i].key === name) return _genericDeclStore.items[i].fieldNames;
		i = i + 1;
	}
	return "";
}

// Get "|"-joined field type annotations for a generic interface/class
export function getGenericDeclFieldTypes(name: string): string {
	let i = 0;
	while (i < _genericDeclStore.items.length) {
		if (_genericDeclStore.items[i].key === name) return _genericDeclStore.items[i].fieldTypes;
		i = i + 1;
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

// Centralized reset for all side-channel stores (prevents stale data across test runs)
export function resetAllSideChannels(): void {
	resetExplicitTypeArgs();
	resetGenericDeclStore();
	resetGenericTypeInsts();
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

// DefaultParamStore DELETED — defaults now stored on FunctionDeclData.fnDefaults
// and read via resolvedSym.declNode (see checkExprPass.ms:fillDefaultArgsForNode)

// ===== Conditional-compilation defines =====
// The table the `when` chain is resolved against (src/compiler/defines.ms, a port of
// Nim condsyms.nim). Deliberately NOT part of resetAllSideChannels: this is build
// CONFIGURATION owned by the driver, not per-parse state that must not leak between
// files. The driver sets it once per compilation; tests set and reset it explicitly.
let _parserDefines: DefineTable = createDefineTable();

export function setParserDefines(t: DefineTable): void { _parserDefines = t; }

export function getParserDefines(): DefineTable { return _parserDefines; }

export function resetParserDefines(): void { _parserDefines = createDefineTable(); }
