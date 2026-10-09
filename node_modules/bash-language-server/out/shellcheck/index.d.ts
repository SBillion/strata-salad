import * as LSP from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';
type LinterOptions = {
    executablePath: string;
    cwd?: string;
    externalSources?: boolean;
    timeoutMs?: number;
    maxConcurrent?: number;
};
export type LintingResult = {
    diagnostics: LSP.Diagnostic[];
    codeActions: Record<string, LSP.CodeAction | undefined>;
};
export declare class Linter {
    private disposed;
    private timeoutMs;
    private maxConcurrent;
    private cwd;
    executablePath: string;
    private externalSources;
    private uriToLintJob;
    private _canLint;
    constructor({ cwd, executablePath, externalSources, timeoutMs, maxConcurrent, }: LinterOptions);
    private static runningJobs;
    private static readyJobs;
    private static drainQueue;
    get canLint(): boolean;
    cancel(uri: string): void;
    dispose(): void;
    /** Returns null when superseded or canceled; callers must not publish that result. */
    lint(document: TextDocument, sourcePaths: string[], additionalShellCheckArguments?: string[]): Promise<LintingResult | null>;
    private executeLint;
    private runShellCheck;
}
export {};
