export interface FmtConfig {
	printWidth?: i32;
	tabWidth?: i32;
	useTabs?: boolean;
	singleQuote?: boolean;
}

export interface BuildConfig {
	root?: string;
	fmt?: FmtConfig;
}
