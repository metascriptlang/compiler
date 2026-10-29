import { assertFmtContains, assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

test "fmt: override on a method is kept" {
	const src = "class C extends B {\n\toverride m(): void {}\n}\n";
	assert assertFmtLossless(src);
	assert assertFmtContains(src, "override m(): void");
}

test "fmt: override keeps its place after static and before async and the generator star" {
	const src = "class C extends B {\n\tpublic static override m(): void {}\n\toverride async a(): void {}\n\toverride *g(): void {}\n\toverride async *ag(): void {}\n}\n";
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
	assert assertFmtContains(src, "public static override m(): void");
	assert assertFmtContains(src, "override async a(): void");
	assert assertFmtContains(src, "override *g(): void");
	assert assertFmtContains(src, "override async *ag(): void");
}

test "fmt: a method named override stays an ordinary method" {
	const src = "class C {\n\toverride(): string {\n\t\treturn \"x\";\n\t}\n}\n";
	assert assertFmtLossless(src);
	assert assertFmtContains(src, "  override(): string");
}
