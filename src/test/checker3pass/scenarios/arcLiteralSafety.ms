import { checkOnly } from "../helpers";

test "contextual Arc literals preserve the constructor's deep-immutable pointee gate" {
	const result = checkOnly("class Cell { value: int32 = 0; }\nstruct SharedData { cell: Cell; }\nconst data: Arc<SharedData> = { cell: new Cell() };");
	assert result.errors.length > 0;
	assert result.errors.join("\n").contains("Arc<T> pointee must be deep-immutable data");
	assert result.errors.join("\n").contains("SharedData");
}

test "an operator refuses an Arc handle against a value and names the read" {
	const sources = [
		"const a: Arc<string> = new Arc(\"hi\");\nconst r = a + \"x\";",
		"const a: Arc<string> = new Arc(\"hi\");\nconst r = \"x\" + a;",
		"const a: Arc<string> = new Arc(\"hi\");\nconst r = a == \"hi\";",
		"const a: Arc<string> = new Arc(\"hi\");\nconst r = `${a}`;",
		"const a: Arc<int32> = new Arc(1);\nconst r = a + 1;",
		"const a: Arc<int32> = new Arc(1);\nconst r = a == 1;",
	];
	for (const src of sources) {
		const result = checkOnly(src);
		assert result.errors.length > 0;
		assert result.errors.join("\n").contains("a[]");
	}
}

test "an Arc handle still reads through an explicit deref in an operator" {
	const result = checkOnly("const a: Arc<string> = new Arc(\"hi\");\nconst b: Arc<int32> = new Arc(1);\nconst r = a[] + \"x\";\nconst q = b[] + 1;\nconst same = a == a;");
	assert result.errors.length == 0;
}
