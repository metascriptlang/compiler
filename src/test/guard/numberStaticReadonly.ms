// The Number constants are readonly statics, as in the TypeScript lib: writing one
// is the same diagnostic as writing any other readonly static.
//
// A red guard means the std declaration or the readonly rule on a callable's statics drifted.
//
// GUARD-CHECK-FAIL cannot assign to 'EPSILON' because it is a read-only property

Number.EPSILON = 1.0;
console.log(`${Number.EPSILON}`);
