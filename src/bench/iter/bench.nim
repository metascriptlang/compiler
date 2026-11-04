# The rows of bench.ms written as a Nim author would: inline iterators for generators, sequtils for eager stages.
# Std Nim has no lazy inline adapters, so a chain consumed in place is one inline iterator running map, filter and
# take in order, and a chain returned from a function is closure iterators. bench() repeats the shared harness.

import std/[algorithm, math, monotimes, sequtils, strutils, times]

const
  Size = 65536
  Side = 256
  MinRoundMs = 250.0

proc timeRound(op: proc ()): float =
  var calls = 1
  while true:
    let start = getMonoTime()
    for _ in 0 ..< calls: op()
    let elapsed = float((getMonoTime() - start).inNanoseconds) / 1e6
    if elapsed >= MinRoundMs: return elapsed / float(calls)
    calls = if elapsed < 1.0: calls * 16 else: int(ceil(float(calls) * (MinRoundMs * 1.2 / elapsed)))

proc bench(name: string, op: proc ()) =
  var rates: seq[float]
  for _ in 0 ..< 3: rates.add(timeRound(op) * 1000.0)
  rates.sort()
  let median = rates[1]
  let spread = (rates[2] - rates[0]) / median * 100.0
  echo alignLeft(name, 28), alignLeft($round(median, 3) & " us/op", 18), "spread ", $round(spread, 1), "%"

var sink = 0.0
var pass = 0

proc nextPass(): int =
  inc pass
  pass

proc filled(count, step, offset: int): seq[int32] =
  for i in 0 ..< count: result.add(int32((i * step + offset) mod 1000))

proc bump(values: var seq[int32]) =
  let at = nextPass() mod values.len
  values[at] += 1

var arr = filled(Size, 7, 3)
let other = filled(Size, 13, 5)
var vec = arr
var grid = newSeq[seq[int32]]()
for r in 0 ..< Side: grid.add(filled(Side, 7, r))

proc indexedSum(values: seq[int32]): int32 =
  for i in 0 ..< values.len: result += values[i]

proc forOfSum(values: seq[int32]): int32 =
  for x in values: result += x

proc valuesSum(values: seq[int32]): int32 =
  for x in values.items: result += x

proc keysSum(values: seq[int32]): int32 =
  for i in values.low .. values.high: result += values[i]

proc entriesSum(values: seq[int32]): int32 =
  for i, x in values: result += x + int32(i and 1)

proc gridSum(rows: seq[seq[int32]]): int32 =
  for row in rows:
    for x in row: result += x

iterator upTo(limit: int32): int32 {.inline.} =
  var i = 0'i32
  while i < limit:
    yield i
    inc i

iterator relay(limit: int32): int32 {.inline.} =
  for x in upTo(limit): yield x

proc generatorSum(salt: int32): int32 =
  for x in upTo(Size): result += (x xor salt) and 1023

proc nestedGeneratorSum(salt: int32): int32 =
  for x in relay(Size): result += (x xor salt) and 1023

proc rangeSum(salt: int32): float =
  for i in salt ..< salt + Size: result += float(i)

iterator doubledNotMult3(values: seq[int32], limit: int): int32 {.inline.} =
  var taken = 0
  if limit > 0:
    for x in values:
      let y = x * 2
      if y mod 3 != 0:
        yield y
        inc taken
        if taken >= limit: break

proc chainForOfSum(values: seq[int32]): int32 =
  for x in doubledNotMult3(values, Size div 2): result += x

proc chainReduceSum(values: seq[int32]): int32 =
  var acc = 0'i32
  for x in doubledNotMult3(values, Size div 2): acc += x
  acc

type Iter = iterator (): int32

# The source holds a ptr to the seq: capturing the seq itself would copy all of it into the environment per call.
proc values(source: ptr seq[int32]): Iter =
  result = iterator (): int32 =
    for x in source[]: yield x

proc map(source: Iter, f: proc (x: int32): int32 {.nimcall.}): Iter =
  result = iterator (): int32 =
    for x in source(): yield f(x)

proc filter(source: Iter, f: proc (x: int32): bool {.nimcall.}): Iter =
  result = iterator (): int32 =
    for x in source():
      if f(x): yield x

proc take(source: Iter, limit: int): Iter =
  result = iterator (): int32 =
    var taken = 0
    if limit > 0:
      for x in source():
        yield x
        inc taken
        if taken >= limit: break

proc makeChain(source: ptr seq[int32]): Iter =
  source.values
    .map(proc (x: int32): int32 = x * 2)
    .filter(proc (x: int32): bool = x mod 3 != 0)
    .take(Size div 2)

proc storedChainSum(source: ptr seq[int32]): int32 =
  let chain = makeChain(source)
  for x in chain(): result += x

proc toArraySum(values: seq[int32]): int32 =
  let output = values.mapIt(it * 2)
  for x in output: result += x

proc zipSum(left, right: seq[int32]): int32 =
  for (x, y) in zip(left, right): result += (x * y) and 1023

proc eagerSum(values: seq[int32]): int32 =
  values.mapIt(it * 2).filterIt(it mod 3 != 0).foldl(a + b, 0'i32)

bench("indexed for int32[]", proc () = sink += float(indexedSum(arr)); bump(arr))
bench("for-of int32[]", proc () = sink += float(forOfSum(arr)); bump(arr))
bench("for-of Vec<int32>", proc () = sink += float(forOfSum(vec)); bump(vec))
bench("for-of values()", proc () = sink += float(valuesSum(arr)); bump(arr))
bench("for-of keys()", proc () = sink += float(keysSum(arr)); bump(arr))
bench("for-of entries()", proc () = sink += float(entriesSum(arr)); bump(arr))
bench("for-of nested 256x256", proc () =
  sink += float(gridSum(grid))
  bump(grid[nextPass() mod Side]))
bench("generator", proc () = sink += float(generatorSum(int32(nextPass()))))
bench("nested generator", proc () = sink += float(nestedGeneratorSum(int32(nextPass()))))
bench("Iterator.range float64", proc () = sink += rangeSum(int32(nextPass())))
bench("chain for-of", proc () = sink += float(chainForOfSum(arr)); bump(arr))
bench("chain reduce", proc () = sink += float(chainReduceSum(arr)); bump(arr))
bench("chain stored in a function", proc () = sink += float(storedChainSum(addr arr)); bump(arr))
bench("map toArray", proc () = sink += float(toArraySum(arr)); bump(arr))
bench("zip product", proc () = sink += float(zipSum(arr, other)); bump(arr))
bench("eager map filter reduce", proc () = sink += float(eagerSum(arr)); bump(arr))

if sink < 0: echo "unreachable ", sink
