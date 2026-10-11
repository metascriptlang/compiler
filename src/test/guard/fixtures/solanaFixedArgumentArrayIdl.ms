import { anchorIdl } from "std/solana/idl";
import { FixedArrayAccounts, FixedArrayInput, FixedArrayOp, ScalarArrayInput } from "./solanaFixedArgumentArrayTypes";

console.log(anchorIdl<FixedArrayOp>({
	name: "fixed_arrays",
	address: "B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32",
	Read: [FixedArrayAccounts, FixedArrayInput],
	Scalar: [FixedArrayAccounts, ScalarArrayInput],
	accounts: [],
	events: [],
	errors: "",
}));
