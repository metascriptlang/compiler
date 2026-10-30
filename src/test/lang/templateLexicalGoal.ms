test "an escaped initial backtick stays inside its template" {
	const value = `\`${7}`;
	assert value == "`7";
	const longer = `\`tick ${7}`;
	assert longer == "`tick 7";
}

test "operator-looking templates remain strings in expression goals" {
	assert `+` == "+";
	assert `==` == "==";
	assert `!=` == "!=";
	assert `[]` == "[]";
	assert `[]=` == "[]=";
	assert `<>` == "<>";
	assert `` == "";
}

test "template escape decoding is shared by initial and middle pieces" {
	const middle = `a${7}\`b${7}`;
	assert middle == "a7`b7";
	const slash = `\\`;
	assert slash == "\\";
	const dollar = `\${name}`;
	assert dollar == "${name}";
}

test "operator-looking arguments do not become macro names" {
	const join = (value: string): string => value + "!";
	assert join(`+`) == "+!";
	assert join(`\\`) == "\\!";
}
