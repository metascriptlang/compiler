// C Header Utilities — shared between aro.ms (native) and aro.jms (JS)

// Strip trailing C qualifiers (restrict, volatile, _Nonnull, etc.)
function stripQualifiers(t: string): string {
	let s = t;
	if (s.endsWith(" restrict")) { s = s.slice(0, s.length - 9); }
	if (s.endsWith(" volatile")) { s = s.slice(0, s.length - 9); }
	if (s.endsWith(" _Nonnull")) { s = s.slice(0, s.length - 9); }
	if (s.endsWith(" _Nullable")) { s = s.slice(0, s.length - 10); }
	if (s.endsWith(" __restrict")) { s = s.slice(0, s.length - 11); }
	return s.trim();
}

// Map a C type string to a MetaScript type annotation string.
export function mapCType(ctype: string): string {
	const t = stripQualifiers(ctype.trim());

	// Pointer types — can't be in match (endsWith check)
	if (t.endsWith("*")) {
		const base = t.slice(0, t.length - 1).trim();
		if (base === "char" || base === "const char") return "string";
		return "int64";
	}

	return match (t) {
		"void" => "void",
		"_Bool" | "bool" | "msBool" => "boolean",
		"msString" => "string",
		"int8_t" | "char" | "signed char" => "int8",
		"int16_t" | "short" | "short int" => "int16",
		"int32_t" | "int" => "int32",
		"int64_t" | "long" | "long int" | "long long" | "long long int" | "ssize_t" | "intptr_t" => "int64",
		"uint8_t" | "unsigned char" => "uint8",
		"uint16_t" | "unsigned short" | "unsigned short int" => "uint16",
		"uint32_t" | "unsigned int" | "unsigned" => "uint32",
		"uint64_t" | "unsigned long" | "unsigned long int" | "unsigned long long" | "unsigned long long int" | "size_t" | "uintptr_t" => "uint64",
		"float" => "float32",
		"double" => "float64",
		_ => "int64",
	};
}

// Generate a valid MetaScript parameter name (avoid reserved words)
export function safeParamName(name: string): string {
	return match (name) {
		"" => "p",
		"type" => "argType",
		"function" => "fn",
		"class" => "cls",
		"interface" => "iface",
		"import" => "imp",
		"export" => "exp",
		"const" => "cnst",
		"let" => "letVal",
		"var" => "varVal",
		"return" => "ret",
		"enum" => "enumVal",
		_ => name,
	};
}

// ===== Tests =====

test "void" { assert mapCType("void") === "void"; }
test "int" { assert mapCType("int") === "int32"; }
test "unsigned int" { assert mapCType("unsigned int") === "uint32"; }
test "float" { assert mapCType("float") === "float32"; }
test "double" { assert mapCType("double") === "float64"; }
test "bool" { assert mapCType("bool") === "boolean"; }
test "_Bool" { assert mapCType("_Bool") === "boolean"; }
test "char" { assert mapCType("char") === "int8"; }
test "unsigned char" { assert mapCType("unsigned char") === "uint8"; }
test "int32_t" { assert mapCType("int32_t") === "int32"; }
test "uint64_t" { assert mapCType("uint64_t") === "uint64"; }
test "size_t" { assert mapCType("size_t") === "uint64"; }
test "char *" { assert mapCType("char *") === "string"; }
test "const char *" { assert mapCType("const char *") === "string"; }
test "void *" { assert mapCType("void *") === "int64"; }
test "int *" { assert mapCType("int *") === "int64"; }
test "msString" { assert mapCType("msString") === "string"; }
test "msBool" { assert mapCType("msBool") === "boolean"; }
test "short" { assert mapCType("short") === "int16"; }
test "long" { assert mapCType("long") === "int64"; }
test "long long" { assert mapCType("long long") === "int64"; }
test "whitespace trimmed" { assert mapCType("  int  ") === "int32"; }
test "safe param name type" { assert safeParamName("type") === "argType"; }
test "safe param name normal" { assert safeParamName("count") === "count"; }
test "safe param name empty" { assert safeParamName("") === "p"; }
