// @stdout: direct=2 helper=3 none=-1 index=6 empty=4 clamped=0
// @skip-js: the JS byte tier exports no findBytesFrom or stringByteIndexOf; search there is String.prototype.indexOf
// note: a std byte search imported into comptime code runs its Raiser tier; bytes.rms declared neither findBytesFrom nor stringByteIndexOf, so a C build stopped with an internal error and a Raiser build refused the import
import { findBytesFrom, stringByteIndexOf } from "std/core/string/bytes";

function secondL(s: string): int64 {
	return findBytesFrom(s.asBytes(), "l".asBytes(), 3);
}

const direct = @comptime { return findBytesFrom("hello".asBytes(), "l".asBytes(), 0); };
const helper = @comptime { return secondL("hello"); };
const none = @comptime { return findBytesFrom("hello".asBytes(), "lo!".asBytes(), 0); };
const index = @comptime { return stringByteIndexOf("hello world", "world", 2); };
const empty = @comptime { return stringByteIndexOf("hello", "", 4); };
const clamped = @comptime { return stringByteIndexOf("hello", "he", -3); };
console.log(`direct=${direct} helper=${helper} none=${none} index=${index} empty=${empty} clamped=${clamped}`);
