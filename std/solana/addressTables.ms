// A SeedSlice points into the frame that built it: valid while that call runs, never returned.
export struct SeedSlice {
	address: uint64;
	length: uint64;
}

export struct SignerSeeds {
	address: uint64;
	length: uint64;
}

// The runtime's SolAccountMeta: the key is the address of the account's key in the input buffer. Core
// builds one from an Account, so every key it makes points at a record the runtime parsed.
export struct InstructionAccount {
	key: uint64;
	writable: uint8;
	signer: uint8;
}
