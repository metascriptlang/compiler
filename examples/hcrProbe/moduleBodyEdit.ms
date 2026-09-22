// HCR probe module — body-only edit of module.ms.
// Same globals (count, scale): identical _GlobalState hash, so state carries
// over and only the function body changes. bump() now doubles.

let count: int32 = 0
let scale: int32 = 10

@exportName("hcrProbeBump")
export function bump(): int32 {
    count += 1
    return count * scale * 2
}
