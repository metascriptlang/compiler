import { compileToCWithStd } from "../helpers";

function comptimeOf(signature: string, call: string): string {
	const c = compileToCWithStd(`@comptime function conv${signature} { return v as ${signature.split("): ")[1]}; }
const k = conv(${call});
console.log(k);`);
	return c.ok ? "ok" : c.error;
}

test "comptimeConversionRange: a float outside an unsigned type stops the @comptime call" {
	assert comptimeOf("(v: float64): uint8", "-1.5").includes("value -1.5 not in range 0 .. 255");
	assert comptimeOf("(v: float64): uint32", "4294967296.0").includes("value 4294967296 not in range 0 .. 4294967295");
	assert comptimeOf("(v: float64): uint64", "-1.0").includes("value -1 not in range 0 .. 18446744073709551615");
}

test "comptimeConversionRange: a float inside an unsigned type folds" {
	assert comptimeOf("(v: float64): uint8", "255.9") == "ok";
	assert comptimeOf("(v: float64): uint64", "18446744073709549568.0") == "ok";
}

test "comptimeConversionRange: a value outside 0 .. 255 stops a @comptime conversion into char" {
	assert comptimeOf("(v: int32): char", "300").includes("value 300 not in range 0 .. 255");
	assert comptimeOf("(v: float64): char", "-1.5").includes("value -1.5 not in range 0 .. 255");
	assert comptimeOf("(v: float64): char", "65.9") == "ok";
}
