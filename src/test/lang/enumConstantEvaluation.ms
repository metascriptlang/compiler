enum Bits { A = 0x10, B = 1 << 2, C }
enum Permissions { Read = 1 << 0, Write = 1 << 1, Both = Read | Write, Qualified = Permissions.Read | Permissions.Write }
enum Negative { Shift = -(1 << 3) }

function localOrdinal(): int32 {
	enum Local { First = 3, Double = First * 2, Next }
	return (Local.Double as int32) * 10 + (Local.Next as int32);
}

test "enum constants: folding and implicit successors use evaluated ordinals" {
	assert (Bits.A as int32) == 16;
	assert (Bits.B as int32) == 4;
	assert (Bits.C as int32) == 5;
	assert (Permissions.Both as int32) == 3;
	assert (Permissions.Qualified as int32) == 3;
	assert (Negative.Shift as int32) == -8;
	assert localOrdinal() == 67;
}
