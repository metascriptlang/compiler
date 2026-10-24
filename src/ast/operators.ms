export function isLogicalAssignOp(op: string): boolean {
	return op == "&&=" || op == "||=" || op == "??=";
}

export function isEagerAssignOp(op: string): boolean {
	return match (op) {
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" | "**=" => true,
		"<<=" | ">>=" | ">>>=" | "&=" | "|=" | "^=" => true,
		_ => false,
	};
}

export function isAssignOp(op: string): boolean {
	return isEagerAssignOp(op) || isLogicalAssignOp(op);
}

export function isComparisonOp(op: string): boolean {
	return match (op) {
		"===" | "!==" | "==" | "!=" => true,
		"<" | "<=" | ">" | ">=" => true,
		_ => false,
	};
}

export function isShiftOp(op: string): boolean {
	return op == "<<" || op == ">>" || op == ">>>";
}

test "the sixteen assignment spellings are assignments and no comparison is" {
	for (const op of ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??="]) {
		assert isAssignOp(op);
	}
	for (const op of ["==", "===", "!=", "!==", "<=", ">=", "<", ">", "+", "&&", ".."]) {
		assert !isAssignOp(op);
	}
}

test "logical assignment is the only assignment the eager predicate refuses" {
	assert isEagerAssignOp("**=") && isEagerAssignOp("=");
	assert !isEagerAssignOp("&&=") && !isEagerAssignOp("??=") && isLogicalAssignOp("||=");
}

test "comparison and shift predicates keep the two classes apart" {
	assert isComparisonOp("!==") && isComparisonOp("<=") && !isComparisonOp("<<=") && !isComparisonOp("=");
	assert isShiftOp(">>>") && !isShiftOp(">>=") && !isShiftOp(">");
}
