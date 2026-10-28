struct Decl__fixture {
	msStringArray* params;
};
void keep__fixture(msStringArray* names_p0) {
	msIncref((void*)names_p0);
}
void emitModuleJob__fixturecompileOms_u0(void) {
	Decl__fixture* d = 0;
	keep__fixture((*d).params);
}
