export declare const BASH_DIALECTS: readonly ["sh", "bash", "dash", "ksh", "zsh", "csh", "ash", "busybox"];
type BashDialect = (typeof BASH_DIALECTS)[number];
export declare function analyzeFile(uri: string, fileContent: string): {
    shebang: string | null;
    directive: string | null;
    dialect: BashDialect | null;
    isDetected: boolean;
};
export {};
