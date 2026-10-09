// GUARD-CHECK-FAIL argument type 'Pubkey' has no IDL type
// GUARD-CHECK-FAIL argument type 'Bytes' has no IDL type
// GUARD-CHECK-FAIL solanaIdlTypeNamesRefused.ms:15:
// GUARD-CHECK-FAIL solanaIdlTypeNamesRefused.ms:16:
// GUARD-CHECK-FAIL solanaIdlTypeNamesRefused.ms:17:
// GUARD-CHECK-FAIL solanaIdlTypeNamesRefused.ms:18:
import { anchorIdl } from "std/solana/idl";
struct Pubkey { value: uint64; }
struct Bytes { value: uint64; }
struct KeyScalar { value: Pubkey; }
struct KeyArray { value: Pubkey[2]; }
struct BytesScalar { value: Bytes; }
struct BytesArray { value: Bytes[2]; }
enum Op { Read }
const keyScalar = anchorIdl<Op>({ name: "key_scalar", Read: [KeyScalar, KeyScalar], accounts: [], events: [], errors: "" });
const keyArray = anchorIdl<Op>({ name: "key_array", Read: [KeyArray, KeyArray], accounts: [], events: [], errors: "" });
const bytesScalar = anchorIdl<Op>({ name: "bytes_scalar", Read: [BytesScalar, BytesScalar], accounts: [], events: [], errors: "" });
const bytesArray = anchorIdl<Op>({ name: "bytes_array", Read: [BytesArray, BytesArray], accounts: [], events: [], errors: "" });
