let returnCalls = 0;

function recordReturn(value: string): void {
	returnCalls += value.length;
}

function returnOnNextLine(): void {
	const held = ["held".repeat(8)];
	return
	recordReturn(held[0]);
}

function returnAcrossComment(): void {
	const held = ["comment".repeat(8)];
	return /*
	*/ recordReturn(held[0]);
}

function returnOnSameLine(): void {
	return /* same line */ recordReturn("same");
}

function returnParenthesized(): void {
	return (
		recordReturn("continued")
	);
}

test "return does not evaluate an operand on the next line" {
	returnCalls = 0;
	returnOnNextLine();
	assert returnCalls == 0;
}

test "a line break inside a comment terminates return" {
	returnCalls = 0;
	returnAcrossComment();
	assert returnCalls == 0;
}

test "same-line return keeps its operand across comments and parentheses" {
	returnCalls = 0;
	returnOnSameLine();
	returnParenthesized();
	assert returnCalls == 13;
}
