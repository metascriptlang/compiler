// @stdout: 4 dc00 d800 dc00 d800 true
// @stdout: 6 d800 true
// @stdout: AB€😀Z ab€😀z ababab 0
// note: repeating a string that ends in a lone high surrogate and starts with a lone low one joins them into one pair where the copies meet, as node does; case mapping and other repeats copy the bytes without a scan. Expected lines from node.

const split = "\uDC00\uD800";
const twice = split.repeat(2);
console.log(`${twice.length} ${twice.charCodeAt(0).toString(16)} ${twice.charCodeAt(1).toString(16)} ${twice.charCodeAt(2).toString(16)} ${twice.charCodeAt(3).toString(16)} ${twice == "\uDC00𐀀\uD800"}`);
const high = "a\uD800";
console.log(`${high.repeat(3).length} ${high.repeat(3).charCodeAt(1).toString(16)} ${high.repeat(1) == high}`);
console.log(`${"aB€😀Z".toUpperCase()} ${"Ab€😀z".toLowerCase()} ${"ab".repeat(3)} ${"x".repeat(0).length}`);
