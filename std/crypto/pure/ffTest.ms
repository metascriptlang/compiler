import {
	Modulus, modulusFromBytes, uintFromBytes, uintToBytes, uintToMinimalBytes, limbsFor, uintDivRem,
	uintDivRemPublic, uintGcd, uintGcdModinvOdd, uintMul, uintIsOne, uintBitLenPublic,
	feFromBytes, reduce, add, sub, mul, sq, pow, powPublic, one, bits,
} from "./ff";

// Values from Zig's own ff tests, and ones Python computed (`pow`, `//`, `%`, `pow(a, -1, n)`).
const small = "8be23ac010dab478010484f2ded7d252f5251d66a7351011";
const smallX = "0345031ca02420101ec3b9aea63597d85626f9619b40d0e5";
const smallY = "011aa01df09fb84095a47cabeb6fb06a7a900b";
const smallXY = "43f7df24f8028bfe6ec6b1f44716b47a42047ef12d959a01";
const smallXPlusY = "0345031ca0253ab03cb45966e6cb3c550212691205bb60f0";
const wide = "60b51410f2dc2f7dcf429602075a8f10c6784c5e288e7e93327f70a2b17b764a44b75458b31c6368602cb5ac14647f26429f0169602099251d66a7351011";
const wideMod = "22fe6e0217458ad425e182ccbb6d88bf34cea89ada0b1b3a";
const smallXPowY = "428e2d4dcfdcd9ef8984b404e9e23739b3e23d6cda96fe69";
const modulus2048 = "d022e8f4fa56820673ae38cc8820c81662b720857e4fb620c7fcc6e3869e9435d24fe2b17f7a0769fcf5088580f8f7388ce84f8151cf034faeb7b9c9c5209c90ff0030191c71640436766c7d4a894774b05d2e9149278fa1c720bbf91d878e94db602352d033997bd73d8e81d5de0d3a3d43f4d0b4ac871c78a132618c1aca9edcb6124729054a97aee4a7edffc78672de847485fb6db32472c1b47f0741328ce0469fa2602985b97518b05112d9d65ff664f742b16dbb7c9e863514f0003e66d0b4bf8e9607ab378aa30de8dc842d83a63c88ce01ab036763286ec63a60f30b052d78b79761d2b37fafad485eeda1d852ae3f0635840ea8a1bef5d3bd9dd94d";
const base2048 = "7156c66b8961d40bffda8644b85d453ce5130345be37c5a623e18ce96f1cf302fcede8d057d8e10d1b90302b81fc2a7f1ace461b0a3aae48a32f52646ffc3049c73e5770edb55d2ca9f47fb5c3e9e02a4f5938ea8d34303738fad75888b1031f75b91e27bf93193c86e94a67032cd744c766e390ca076ff18516e6f6fc9d2df2cebe60efd949039fa8d8bac7d3e17db03f3e060531a329396ff9f9ab618600487e6efa1059fa75c882f01ab7d0564b58030dfdf6846db25d7e02dd90b8f9c58350c7f5878858c561e5d2a665f3f51da1f590c1150948b33dade79a8f3868c7849aa74e2c2741705cfae461bc360850a4bf77df2a6a8b0c50bd40fa4a2e73527e";
const exponent2048 = "3c79c409a6706ad5aeed93849b5146e94fcbda0298bb04873390bc02bbdeb86868702e1dc73988b91b744f5ac4734fe140f0798c9407786c9e00e0f58ea5bcf2a1a396549000b3ee1810c45bcda6254262d615c68a4155919cae765db915fdb31fe6feb287714ee897368832984840c2b09a8ddd174e0442617778dca18a05b0388a8fcfc30a882ccd04b8bbaf013077fad9306d4ae14d871a1aa4f12a5d07393906ea0172245f32c32512983d96e4e569e39f6dfdf881baa0e8d7694fb3d533e8df39e65e138500e342994ab3cdeb71d6f4101014558aef2a8495ca103f4d9a5f0fca36eaa1b8319ce520d24202325ec6ac146cfd617a60d95b8e090140e3e7";
const power2048 = "5977d9eea937ae180079d43e59cc743f84bfcd04f63aec636b8d2d04836c1079ec6efb98fe8e6298cf1cab7da8b613d1c654faac7e85ef6a727544d214c5d6ae40e5c19346c161a95fd56ea95213d173b4ff95c84f4ed9e429826ddd68269cc159c84975db40767fb8f68f8339248157a8250afe155a4228d1e6e2b9b7b52f9c685f8a4f182e5f809b2a61e316f55ddda5e09471a9c760df3cfdef3f8947cfe042f2cdfad105a52327a22b9cd4a551882d7879b446a91cff548e4649a4379f8474f01ac5da382cf2560053e4c9dea2cb019bcc8bab24e71211cd1b10857c4c35b8cbc8104aeccd4df7726b42525c54923e5695aa07321989a7b313d612b8370a";
const inverseA = "57e00902c77ebff206867347214cdd2055930d6eaf14f4733f3e7d1bfbc7a2ea20b2f14c942e05319acb5c74273f98e2774cbd87ad5c90a9587403e430ec66a78795e761d17731af10506bf2efc6f877186d76b07e881ed162ae2eb1547f15052434b9b5df9e7769b10f4205b4907a70c31012f037b64ce4228c38fb29";
const inverseN = "ff26144b98289fcd59a54a7bb1fee08f571242425051c1ccd17f9acae01f5057ca02135e92b1d3f28ede0d7ac3baea9e13deef86ab1031d0f646e1f40a097c976bf46c697d2caf82eeeacbe226e875555790f82ec1d3fcff2a3af4d46b0a18e8830e07bc1e398f1012bd4acefaecbd389be4bcfc49b64a0872e6cc3ababced21";
const inverseOfA = "820c024a8b2e6bd6b06c158fc27241c77f695171103314dfe47e4ac1321b90092b32ab9acfa3f11cd7968d4b56d939bd0806048c79ec0297f5230edc4da747ab83fc58aabe89af6decef4ff183a8c4bd0cbe09f13e2ba78a8b369b21fa2be3cec05da63888491b574a3619092457273fec1070ae4c37f8d22e3b7133e3252573";
const dividend = "3571810afc132d0d113db17d30cbc97d0fef792866836886a260cd0b7b45145c1a81682c64e50cad66237a0465e7e4236472f1a38f2c6ec8cc4169a3ae3a2b7fdfe01893f3aed0b6c7ac1491def88334e647cb8f74e69a5d0dd27a65bd628881ad1b72dba7abe1c29e1a8ef4f341e07a83f73f16dbf4a8b2b0c4312d20203626f3fe39c0519088f590fbbd119c1caaf75e8766ed88daf4016b4013ef254b0c4e010c4759482c9cbc43435cc52eae05cf96d0cc5fd4c28c2e7c26847f0316909e3bbbe9eaa8948c893b61867626bb7dbd2d1c9af0153e7c2a26a2c0bd3b1287fff52ddf5d616499c9e25a7605aec6f0245bd86d40fc891b4a6a50df4db4d66a3a47469a4d8cdb305fdd2e16096e36aab0d1bc52d9230d977ee22571594720771f8ca8181166d2287672fdf2022a96fb1a14a0f9e77f1b103cdf1582b0eab477d26415479c65dc9f503f63af83bd0561e6211c70cf49952399c4aaeac137dc76fb0f17a3007e62aa0a1df9fd789c6539382b0537e65affb2297631a992f0ce583505c6af0758d5563dab2cd31ee315128862c33a4fb774eb5248db40af72158370d269a9a5ae658f33fe3b890b93f448b3a5aa3c814f426dcbb394fb36bb2d420f0f88080b10a3d6b2aa05e11ab2715945795e8229451abd81f1d69ed617f5e837d70820fe119a72d174c9df6acc011cdd9474031b";
const divisor = "01842a0dd8835bd40aea87161ab217615089ca4b0f7cd6b9379e6b0e77c0f1e76f4a1be6e794a66911f0ec0bd333e7085cff8452a814dd625543eda85fbb76f50def44878e37357b0f50caaf6df6fd7fd542aa3451ef6649c9c4b42bf9133c9fab1b7cf7b92d16f5f658d0ee962baff4a53747fc77f5b4f9e40e49b2a7dc4c3b0f9d863ee52d56f2c3fb24ba73a151345df01eb1dd0ae3e9331af88127edbd44d1550e4c0ecf3ac0a122953a6740386a78c639bfa87e6e2400673a0d0e73f53a3bc540ba2b145fe5dc9c8a33f3233912bfaf664d7298ff2231762c001e9390346b19401aeb30bb33928612ae1b832a384885f25319674ae199d862";
const quotient = "233f26c7a83be1799f42fb864cc4a7da988be43c371a503d4e446e5db958d3ae816bd8f11963dffced2fd147fb7d02d085c0bafff9acd740240c2380d359ae267da14c1c01465b53bdb225e5f7efecf058cf294243cd0251cd4b0c36e7cf6fc210c1ad0f73850bc7b80c3b724b9368288c92d6203a7037b973e7db9da5f00bfac113c1345d45fe80c358d8a465a3b62c0f314d5f585ee25c0cdef61199a94723aa35ad0e3847bfc6ae72121cd5d09565104f4f2ebefb9d6e320080ceaef38c212297f7c30615ed706b23c68c73669af445686ac5634807ab2299c222d47ae1546d58ad165720061e7536a88545fba23f8a2ad652301eb5036230";
const remainder = "c412c738102ce5c5a787ff70c9701cdde074baea965fff0418d4039173e64b75dab94eb59fad6aa092b87b3c2004f3c4c25cb9c4344765f0f8b53a18af8ab723d697e4c2035e52160e5b7c1f98be39a0a56fdb27012c8f7d5de20b552c4f7c159663be2efc2d4f3db5de35d0ece7140654c9bb8e60398d3cdd7c636e6b07dee4dd4cdf458fd6fbe6a918b818475e21032001a245301ba511cca920e361d94f59ed3e5b103d1e48ca870fe15786a12cb34cfc7bdd327a6ac9dbfdd61195b09cf8d788ec140a722255cbb4067556a02a5e7ec3e72d8f925ad48079b5d06fb0d40ba12ff70801781cab381550210390d866b786d252ee2f8f9fecbb";

function uintOf(hex: string): uint32[] {
	const bytes = hex.decodeHex();
	const value = uintFromBytes(bytes, limbsFor(bytes.length * 8));
	if (value == null) throw new Error("fixture does not fit its own width");
	return value;
}

function modulusOf(hex: string): Modulus {
	const m = modulusFromBytes(hex.decodeHex());
	if (m == null) throw new Error("fixture modulus is not odd");
	return m;
}

function feOf(m: Modulus, hex: string): uint32[] {
	const fe = m.feFromBytes(hex.decodeHex());
	if (fe == null) throw new Error("fixture is not below its modulus");
	return fe;
}

function hexOf(x: Readonly<uint32[]>): string {
	return uintToMinimalBytes(x).encodeHex();
}

test "bytes round-trip through limbs and refuse what does not fit" {
	const x = uintOf(base2048);
	assert hexOf(x) == base2048;
	const exact = uintToBytes(x, 257);
	assert exact != null && exact.encodeHex() == "00" + base2048;
	assert uintToBytes(x, 255) == null;
	assert uintFromBytes(base2048.decodeHex(), 2) == null;
	assert uintBitLenPublic(uintOf(modulus2048)) == 2048;
}

test "a 192-bit field multiplies, adds, subtracts and reduces as Zig's tests say" {
	const m = modulusOf(small);
	assert m.bits() == 192;
	const x = feOf(m, smallX);
	const y = feOf(m, smallY);
	assert hexOf(m.mul(x, y)) == smallXY;
	assert hexOf(m.add(x, y)) == smallXPlusY;
	assert hexOf(m.sub(m.add(x, y), y)) == smallX;
	assert hexOf(m.reduce(uintOf(wide))) == wideMod;
	assert m.feFromBytes(small.decodeHex()) == null;
}

test "Montgomery form round-trips and squaring matches multiplying" {
	const m = modulusOf(modulus2048);
	const x = feOf(m, base2048);
	assert hexOf(m.mul(x, m.one())) == base2048;
	assert hexOf(m.sq(x)) == hexOf(m.mul(x, x));
}

test "small and 2048-bit powers match Python with public and secret exponents" {
	const m = modulusOf(small);
	const x = feOf(m, smallX);
	const publicPower = m.powPublic(x, smallY.decodeHex());
	const secretPower = m.pow(x, smallY.decodeHex());
	assert publicPower != null && hexOf(publicPower) == smallXPowY;
	assert secretPower != null && hexOf(secretPower) == smallXPowY;
	const zeroExponent: uint8[] = [0, 0];
	assert m.pow(x, zeroExponent) == null;
	const big = modulusOf(modulus2048);
	const power = big.pow(feOf(big, base2048), exponent2048.decodeHex());
	assert power != null && hexOf(power) == power2048;
	const tiny = big.powPublic(feOf(big, "03"), [1, 0, 1]);
	const tinySecret = big.pow(feOf(big, "03"), [1, 0, 1]);
	assert tiny != null && tinySecret != null && hexOf(tiny) == hexOf(tinySecret);
}

test "division of any divisor gives Python's quotient and remainder" {
	const result = uintDivRem(uintOf(dividend), uintOf(divisor));
	assert hexOf(result.quotient) == quotient;
	assert hexOf(result.remainder) == remainder;
	const product = uintMul(uintOf(quotient), uintOf(divisor));
	assert hexOf(uintDivRem(product, uintOf(divisor)).remainder) == "00";
	const small = uintOf("03e8");
	assert uintDivRemPublic(small, 7) == 6;
	assert hexOf(small) == "8e";
}

test "gcd and the odd-modulus inverse" {
	const gcd = uintGcd(uintOf("0f" + "00".repeat(25)), uintOf("0150" + "00".repeat(12)));
	assert gcd != null && hexOf(gcd) == "30" + "00".repeat(12);
	const found = uintGcdModinvOdd(uintOf(inverseA), uintOf(inverseN));
	assert uintIsOne(found.gcd) && hexOf(found.inverse) == inverseOfA;
	const shared = uintGcdModinvOdd(uintOf("06"), uintOf("0f"));
	assert hexOf(shared.gcd) == "03";
}
