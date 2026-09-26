// GUARD-OS solana
// GUARD-CHECK-FAIL @compile failed for
// GUARD-CHECK-FAIL solanaBrokenNative.c
// A C compile error in an @compile source fails an --os=solana build instead of
// dropping the object.
import { logU64 } from "std/solana";
@compile("./fixtures/solanaBrokenNative.c")
logU64(1);
