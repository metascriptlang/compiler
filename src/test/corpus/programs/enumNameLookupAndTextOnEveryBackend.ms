// @stdout: lookup Block Other Two|text Other Other Other Other|valued Mid 20 Low|log Other
// @exit: 0

enum Kind { Block, Other }
enum Level { Low = 5, Mid = 20, High = 100 }
enum Wide { Zero, One, Two }

const e = Kind.Other;
const level = Level.Mid;
const index: int32 = 2;
console.log(`lookup ${Kind[Kind.Block]} ${Kind[e]} ${Wide[index]}|text ${e.toString()} ${String(e)} ${e} ${"" + e}|valued ${Level[level]} ${level as int32} ${Level[5]}|log`, e);
