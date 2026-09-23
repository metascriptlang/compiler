// @stdout: -1|0|-5|-4|7
// @exit: 0

// An enum member initialized with a negated literal keeps its sign, and the next member counts
// on from it; the parser used to skip `-1` and keep the ordinal.
enum Signed { Neg = -1, Zero = 0 }
enum Run { Low = -5, Next, Hi = 7 }
console.log(`${Signed.Neg as int32}|${Signed.Zero as int32}|${Run.Low as int32}|${Run.Next as int32}|${Run.Hi as int32}`);
