// A SeedSlice points into the frame that built it: valid while that call runs, never returned.
export struct SeedSlice {
	address: uint64;
	length: uint64;
}

export struct SignerSeeds {
	address: uint64;
	length: uint64;
}
