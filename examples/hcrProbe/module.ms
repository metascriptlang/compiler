// HCR single-image probe module — the executable contract for S0.
//
// One image, no imports: hcrLift lifts both globals into _GlobalState.
// v1 behavior: bump() returns count * 10.
// A body-only edit changes the multiplier without touching the layout.
// A layout edit adds a field, which must change the structural hash.

let count: int32 = 0
let scale: int32 = 10

@exportName("hcrProbeBump")
export function bump(): int32 {
    count += 1
    return count * scale
}
