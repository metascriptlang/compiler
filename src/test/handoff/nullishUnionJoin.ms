import { compileToC, compileToJS } from "../helpers";

const pickUnion = "function pick(k: int32): number | string | null { if (k == 0) return null; return \"row\"; }\n";
const pickInt = "function pickInt(k: int32): int32 | null { if (k == 0) return null; return 5; }\n";

test "nullishUnionJoin: the fallback is built into the union's string member" {
	const r = compileToC(pickUnion + "function f(): string { const b: number | string = pick(0) ?? \"fallback\"; return b as string; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains(", 8)}"), r.value;
	assert !r.value.contains(", 8)))"), r.value;
}

test "nullishUnionJoin: the present value is widened into the union's int member" {
	const r = compileToC(pickInt + "function f(): int32 { const r: int32 | string = pickInt(1) ?? \"y\"; return r as int32; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("._tag=0, .v0="), r.value;
	assert r.value.contains("._tag=1, .v1="), r.value;
}

test "nullishUnionJoin: JS keeps both operands as they are" {
	const r = compileToJS(pickInt + "function f(): int32 { const r: int32 | string = pickInt(1) ?? \"y\"; return r as int32; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("\"y\""), r.value;
}
