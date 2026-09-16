// The Math constants are readonly statics, as in the TypeScript lib: writing one
// is the same diagnostic as writing any other readonly static.
//
// A red guard means the std declaration or the readonly rule drifted.
//
// GUARD-CHECK-FAIL cannot assign to 'PI' because it is a read-only property

Math.PI = 3.0;
console.log(`${Math.PI}`);
