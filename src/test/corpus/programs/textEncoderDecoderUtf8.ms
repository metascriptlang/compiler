// @stdout: encode utf-8 104,195,169,240,159,152,128 empty=0 lone=97,239,191,189,98
// @stdout: decode utf-8 hé😀 sub=hé cut=3 none=0
// @stdout: repair 6 65533 array=hi
// @stdout: bom 1 kept=2
// @stdout: fatal=true ignoreBOM=false ok=hé
// @stdout: strict true
// @stdout: label true
// note: TextEncoder and TextDecoder as the Encoding Standard defines UTF-8: encode gives a Uint8Array and a lone surrogate becomes U+FFFD; decode takes any byte span (a typed array, a subarray, an array), turns each ill-formed sequence and encoded surrogate into one U+FFFD per maximal subpart, drops a leading BOM unless ignoreBOM, throws TypeError when fatal, and refuses a label other than UTF-8 with RangeError. Same output on every lane as on Node.

const enc = new TextEncoder();
const bytes = enc.encode("hé😀");
console.log(`encode ${enc.encoding} ${bytes.join(",")} empty=${enc.encode().length} lone=${enc.encode("a\uD800b").join(",")}`);

const dec = new TextDecoder();
console.log(`decode ${dec.encoding} ${dec.decode(bytes)} sub=${dec.decode(bytes.subarray(0, 3))} cut=${dec.decode(bytes.subarray(0, 5)).length} none=${dec.decode().length}`);

const bad = new Uint8Array([0x61, 0xED, 0xA0, 0x80, 0x62, 0xFF]);
console.log(`repair ${dec.decode(bad).length} ${dec.decode(bad).charCodeAt(1)} array=${dec.decode([0x68, 0x69])}`);

const bom = new Uint8Array([0xEF, 0xBB, 0xBF, 0x41]);
console.log(`bom ${dec.decode(bom).length} kept=${new TextDecoder("UTF8", { ignoreBOM: true }).decode(bom).length}`);

const strict = new TextDecoder("utf-8", { fatal: true });
console.log(`fatal=${strict.fatal} ignoreBOM=${strict.ignoreBOM} ok=${strict.decode(bytes.subarray(0, 3))}`);
try {
	strict.decode(bad);
} catch (e) {
	console.log(`strict ${e instanceof TypeError}`);
}
try {
	new TextDecoder("no-such-encoding");
} catch (e) {
	console.log(`label ${e instanceof RangeError}`);
}
