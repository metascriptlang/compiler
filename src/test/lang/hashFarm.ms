// hashFarm over a string's bytes equals the reference's string hash. Each pair is the string and
// the hash the reference computes for its bytes: every length branch (0, 1-3, 4-7, 8-16, 17-32,
// 33-64 and the 64-byte loop with its tail) and non-ASCII text.
import { hashFarm, hashString } from "std/core/struct";

struct FarmVector {
	s: string;
	h: int64;
}

const farmVectors: FarmVector[] = [
	{ s: "", h: -7286425919675154353 },
	{ s: "$", h: -7233930772312226865 },
	{ s: "$+", h: 2329868351898238553 },
	{ s: "$+2", h: 4237981211716197537 },
	{ s: "$+29", h: 4233546591410155541 },
	{ s: "$+29@", h: 141152629890313345 },
	{ s: "$+29@G", h: -6026124960049559114 },
	{ s: "$+29@GN", h: 6551785722678735258 },
	{ s: "$+29@GNU", h: 7915752876838883097 },
	{ s: "$+29@GNU\\", h: -4160388864805322326 },
	{ s: "$+29@GNU\\cjqx!(", h: -4779742498550480239 },
	{ s: "$+29@GNU\\cjqx!(/", h: -2332876112792585485 },
	{ s: "$+29@GNU\\cjqx!(/6", h: -1024139188946312832 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`g", h: -624126852182161423 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:", h: -2280738140154728095 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:A", h: 1503424308260766175 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AH", h: -5114507115097987371 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELS", h: -897148051156176347 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^", h: -1651658632164279070 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^e", h: 424370839909679405 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^el", h: -4697313173652844104 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@G", h: 2419979053357823602 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AH", h: -3311230512800562816 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHO", h: -428169786874219451 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV", h: -8074626482700436416 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjq", h: -4211686523366003131 },
	{ s: "$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BIPW^elsz#*18?FMT[bipw~'.5<CJQX_fmt{$+29@GNU\\cjqx!(/6=DKRY`gnu|%,3:AHOV]dkry\")07>ELSZahov}&-4;BI", h: -3380298715513591529 },
	{ s: "k0", h: -4200605769338195404 },
	{ s: "k999", h: 8758580623932415505 },
	{ s: "héllo wörld ✓ 日本語", h: -6259126417457439202 },
	{ s: "日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語", h: 3077165823139348445 },
];

test "a string hashes to the reference's hashFarm for every length branch" {
	for (const v of farmVectors) {
		assert hashString(v.s) == v.h, `hash of a ${v.s.byteLength}-byte string`;
	}
}

const multiBytePieces: string[] = ["é", "日", "ß", "€", "ü", "語", "✓", "ñ"];

function farmInput(len: int32): string {
	let s = "";
	let i: int32 = 0;
	while (s.byteLength < len) {
		const piece = multiBytePieces[i % 8];
		if (i % 3 == 1 && piece.byteLength <= len - s.byteLength) {
			s += piece;
		} else {
			s += String.fromCharCode(33 + (i * 7) % 90);
		}
		i = i + 1;
	}
	return s;
}

struct FarmBoundary {
	len: int32;
	h: int64;
}

const farmBoundaries: FarmBoundary[] = [
	{ len: 0, h: -7286425919675154353 },
	{ len: 1, h: -1459307080660855630 },
	{ len: 2, h: -3245377973713539183 },
	{ len: 3, h: 1502982227347875767 },
	{ len: 4, h: -6052264090671492281 },
	{ len: 5, h: -4740361854840842962 },
	{ len: 7, h: 6508798854405788457 },
	{ len: 8, h: 9178820140425197559 },
	{ len: 9, h: 8600668962426277906 },
	{ len: 15, h: -2711361252893743389 },
	{ len: 16, h: 20700482545660186 },
	{ len: 17, h: -3756524715969020908 },
	{ len: 24, h: -7016000420833704117 },
	{ len: 31, h: -3412642471000863413 },
	{ len: 32, h: -4772905594073404675 },
	{ len: 33, h: 2440207308259438366 },
	{ len: 48, h: -8094225882468158327 },
	{ len: 63, h: -714695674669876527 },
	{ len: 64, h: 1514324311622918298 },
	{ len: 65, h: -7234370128720440227 },
	{ len: 100, h: -4296955606318437727 },
	{ len: 127, h: 280313738596540298 },
	{ len: 128, h: -4011982847677367922 },
	{ len: 129, h: -719242291507778984 },
	{ len: 191, h: 2619377369322252106 },
	{ len: 192, h: 107427516177264626 },
	{ len: 193, h: -7144222755226846986 },
	{ len: 1000, h: -4514120196060668950 },
];

test "hashFarm keeps its bits at every length-class boundary over multi-byte text" {
	for (const v of farmBoundaries) {
		const s = farmInput(v.len);
		assert s.byteLength == v.len, `input of ${v.len} bytes`;
		assert hashFarm(s) == v.h, `hashFarm of a ${v.len}-byte string`;
	}
}

test "a Map keyed by string keeps its insertion order and finds every key" {
	const m = new Map<string, int32>();
	let i: int32 = 0;
	while (i < 300) { m.set(`k${i}`, i); i = i + 1; }
	i = 0;
	for (const [k, v] of m) {
		assert k == `k${i}` && v == i;
		i = i + 1;
	}
	assert i == 300 && m.size == 300;
	i = 0;
	while (i < 300) { assert (m.get(`k${i}`) ?? -1) == i; i = i + 1; }
	m.delete("k7");
	assert !m.has("k7") && m.has("k8") && m.size == 299;
}
