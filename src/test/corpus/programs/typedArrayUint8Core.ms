// @stdout: new 0,0,0 len=3 bytes=3 off=0 per=1
// @stdout: from 1,2,250 at=250 write 1,9,250
// @stdout: sub 7,250 off=1 len=2 shared 1,7,250 back=7
// @stdout: slice 7,250 copied 1,7,250 own=5,250
// @stdout: neg 7,250 empty=0 clamp=3
// @stdout: buffer len=4 view 0,4,4,0 off=1 tail=4,0 copy=4,4,0
// @stdout: fill 6,6,6,1 set 6,2,3,1
// @stdout: join 6-2-3-1 str 6,2,3,1
// @stdout: from 1,2,3 sub 9,1 own 6,2,3,1
// note: Uint8Array and ArrayBuffer as TS defines them: `new` by length, from bytes, and over a buffer with an offset and a length; a subscript reads and writes the view; subarray shares the bytes while slice copies them; relative and clamped begin and end; fill, set and join; `Uint8Array.from` copies an array or a view into a new buffer. Same output on every lane as on Node.

const z = new Uint8Array(3);
console.log(`new ${z.join(",")} len=${z.length} bytes=${z.byteLength} off=${z.byteOffset} per=${Uint8Array.BYTES_PER_ELEMENT}`);

const a = new Uint8Array([1, 2, 250]);
const at = a[2];
a[1] = 9;
console.log(`from 1,2,250 at=${at} write ${a.join(",")}`);

const s = a.subarray(1);
s[0] = 7;
console.log(`sub ${s.join(",")} off=${s.byteOffset} len=${s.length} shared ${a.join(",")} back=${a[1]}`);

const c = a.slice(1);
c[0] = 5;
console.log(`slice ${a.slice(1).join(",")} copied ${a.join(",")} own=${c.join(",")}`);

console.log(`neg ${a.subarray(-2).join(",")} empty=${a.subarray(2, 1).length} clamp=${a.slice(-10, 10).length}`);

const buf = new ArrayBuffer(4);
const v = new Uint8Array(buf, 1, 2);
v[0] = 4;
v[1] = 4;
const whole = new Uint8Array(buf);
const tail = new Uint8Array(buf, 2);
const rest = buf.slice(1);
const copy = new Uint8Array(rest);
console.log(`buffer len=${buf.byteLength} view ${whole.join(",")} off=${v.byteOffset} tail=${tail.join(",")} copy=${copy.join(",")}`);

const f = new Uint8Array(4).fill(6, 0, 3);
f[3] = 1;
const filled = f.join(",");
f.set([2, 3], 1);
console.log(`fill ${filled} set ${f.join(",")}`);
console.log(`join ${f.join("-")} str ${f.toString()}`);

const fromArray = Uint8Array.from([1, 2, 3]);
const fromView = Uint8Array.from(f.subarray(2));
fromView[0] = 9;
console.log(`from ${fromArray.join(",")} sub ${fromView.join(",")} own ${f.join(",")}`);
