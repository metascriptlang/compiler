struct CEmissionFacts__fixture {
	HashSet_f1x__string* names;
};
struct HashSet_f1x__string {
	int32_t len;
};
void emitModuleJob__fixturecompileOms_u0(void) {
	CEmissionFacts__fixture* f = 0;
	msIncref((*f).names);
}
