// @stdout: direct=23 helper=24 repaired=3
// @skip-js: the JS byte tier exports no utf8Text; text decoding there is TextDecoder
// note: a std routine imported into comptime code runs its Raiser tier; the C tier of utf8Text reads words through a pointer cast the VM has no memory for, and stopped the build with an internal BitAnd register error
import { utf8Text } from "std/core/string/bytes";

function decodedLength(raw: string): int64 {
	return utf8Text(raw, false).length as int64;
}

const direct = @comptime { return utf8Text("hello world hello world", false).length as int64; };
const helper = @comptime { return decodedLength("hello world hello world!"); };
const repaired = @comptime { return decodedLength("aéb"); };
console.log(`direct=${direct} helper=${helper} repaired=${repaired}`);
