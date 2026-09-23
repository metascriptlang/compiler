import { assertFmtLossless } from "../roundtrip";

test "fmt: interface keeps its extends clause" {
	assert assertFmtLossless("interface HostProps { id: string; }\ninterface ViewProps extends HostProps {\n\tflex: number;\n}\n");
}

test "fmt: empty interface keeps several generic parents" {
	assert assertFmtLossless("interface A<T> { a: T; }\ninterface B { b: int32; }\ninterface C extends A<int32>, B {}\n");
}
