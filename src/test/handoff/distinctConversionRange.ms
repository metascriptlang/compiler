import { hasError, strictErrorCount } from "./helpers";

const types = "type Small = distinct int8; type Byte = distinct uint8; type Big = distinct uint64; type Ratio = distinct float32; ";

function accepts(body: string): boolean {
	return strictErrorCount(types + body) == 0;
}

function refuses(body: string, message: string): boolean {
	return hasError(types + body, message);
}

test "distinct conversion range: a literal outside a signed base is refused, naming the distinct type" {
	assert refuses("const v = 300 as Small;", "cannot convert 300 to Small");
	assert refuses("const v = (-129) as Small;", "cannot convert -129 to Small");
	assert refuses("const v = (100 + 200) as Small;", "cannot convert 300 to Small");
	assert refuses("const i: int32 = 300; const v = i as Small;", "cannot convert 300 to Small");
	assert refuses("const v = 300 as int8;", "cannot convert 300 to int8");
	assert accepts("const v = 127 as Small; const w = (-128) as Small;");
}

test "distinct conversion range: a literal outside an unsigned base is refused, naming the distinct type" {
	assert refuses("const v = 300 as Byte;", "cannot convert 300 to Byte");
	assert refuses("const v = (-1) as Byte;", "cannot convert -1 to Byte");
	assert accepts("const v = 255 as Byte; const w = 18446744073709551615 as Big; const x = 9223372036854775808 as Big;");
}

test "distinct conversion range: a float literal into an integer base is refused outside its range" {
	assert refuses("const v = 300.5 as Small;", "cannot convert 300.5 to Small");
	assert refuses("const v = (-1.5) as Byte;", "cannot convert -1.5 to Byte");
	assert accepts("const v = 2.5 as Small; const w = 255.9 as Byte;");
}

test "distinct conversion range: a float base keeps the float32 literal range" {
	assert strictErrorCount(types + "const v = 1e40 as Ratio;") == strictErrorCount("const v = 1e40 as float32;");
	assert strictErrorCount("const v = 1e40 as float32;") > 0;
	assert accepts("const v = 1.5 as Ratio;");
}
