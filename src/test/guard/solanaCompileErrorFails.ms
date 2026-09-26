// GUARD-OS solana
// GUARD-CHECK-FAIL @compile failed for
// GUARD-CHECK-FAIL solanaBrokenNative.c
import { logU64 } from "std/solana";
@compile("./fixtures/solanaBrokenNative.c")
logU64(1);
