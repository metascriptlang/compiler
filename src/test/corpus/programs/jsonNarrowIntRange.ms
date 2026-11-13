// JSON.parse<T> into a sized-integer field returns a failed Result naming the field and the
// type when the number does not fit, at every width and signedness, in an array element, a
// nested struct and a distinct field; the boundary values of each width are accepted.
//
// @stdout: error field 'workers': expected int32, got 3000000000
// @stdout: error field 'level': expected uint8, got 256
// @stdout: error field 'level': expected uint8, got -1
// @stdout: error field 'port': expected int16, got 40000
// @stdout: error field 'xs[1]': expected int32, got 3000000000
// @stdout: error field 'inner.level': expected uint8, got 300
// @stdout: error field 'host': expected int32, got 4294967297
// @stdout: error field 'total': expected uint64, got -1
// @stdout: error field 'bytes[2]': expected uint8, got -5
// @stdout: ok 2147483647 -2147483648 255 0
// @stdout: ok 127 -128 65535 4294967295 9223372036854775807
// @exit: 0

type HostId = distinct int32;

struct Narrow { workers: int32; }
struct Small { level: uint8; }
struct Port { port: int16; }
struct Many { xs: int32[]; }
struct Bytes { bytes: uint8[]; }
struct Inner { level: uint8; }
struct Outer { inner: Inner; }
struct Host { host: HostId; }
struct Wide { total: uint64; }
struct Edge32 { hi: int32; lo: int32; }
struct Edge8 { hi: uint8; lo: uint8; }
struct Rest { a: int8; b: int8; c: uint16; d: uint32; e: uint64; }

function show<T>(input: string): void {
	const parsed = JSON.parse<T>(input);
	if (!parsed.ok) {
		console.log(`error ${parsed.error}`);
	}
}

show<Narrow>('{"workers":3000000000}');
show<Small>('{"level":256}');
show<Small>('{"level":-1}');
show<Port>('{"port":40000}');
show<Many>('{"xs":[1,3000000000]}');
show<Outer>('{"inner":{"level":300}}');
show<Host>('{"host":4294967297}');
show<Wide>('{"total":-1}');
show<Bytes>('{"bytes":[1,2,-5]}');

const e32 = JSON.parse<Edge32>('{"hi":2147483647,"lo":-2147483648}');
const e8 = JSON.parse<Edge8>('{"hi":255,"lo":0}');
if (e32.ok && e8.ok) console.log(`ok ${e32.value.hi} ${e32.value.lo} ${e8.value.hi} ${e8.value.lo}`);
const rest = JSON.parse<Rest>('{"a":127,"b":-128,"c":65535,"d":4294967295,"e":9223372036854775807}');
if (rest.ok) console.log(`ok ${rest.value.a} ${rest.value.b} ${rest.value.c} ${rest.value.d} ${rest.value.e}`);
