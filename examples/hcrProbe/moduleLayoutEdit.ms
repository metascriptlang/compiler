let count: int32 = 0
let scale: int32 = 10
let pad: int32 = 0

@exportName("hcrProbeBump")
export function bump(): int32 {
    count += 1
    return count * scale
}
