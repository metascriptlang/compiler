import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

test "fmt: type-argument closers written apart in a type annotation" {
	assert assertFmtLossless("let t: Array<Array<int32> > = [];\n");
	assert assertFmtLossless("let t: Array<Array<Array<int32> > > = [];\n");
	assert assertFmtIdempotent("let t: Array<Array<int32> > = [];\n");
}

test "fmt: type-argument closers written apart in an arrow return type" {
	assert assertFmtLossless("const f = (): Array<Array<int32> > => [];\n");
	assert assertFmtLossless("const f = (): Array<Array<int32> >[] => [];\n");
}
