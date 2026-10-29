test "a cut inside a multibyte sequence reads as one U+FFFD per maximal subpart" {
	assert "a€b".byteSlice(2, 5) == "��b";
	assert "a€b".byteSlice(0, 3) == "a�";
	assert "😀".byteSlice(1, 4) == "���";
	assert "😀".byteSlice(0, 3) == "�";
	assert "\uD800".byteSlice(0, 2) == "��";
}

test "a cut on sequence boundaries copies the bytes unchanged" {
	assert "a€b😀c".byteSlice(1, 9) == "€b😀";
	assert "é".byteSlice(0, 2) == "é";
	assert "abc".byteSlice(1, 2) == "b";
}
