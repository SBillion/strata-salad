type Directive = {
    type: 'enable';
    rules: string[];
} | {
    type: 'disable';
    rules: string[];
} | {
    type: 'source';
    path: string;
} | {
    type: 'source-path';
    path: string;
} | {
    type: 'shell';
    shell: string;
};
export declare function parseShellCheckDirective(line: string): Directive[];
/** Extend a disable list without rewriting other directives or explanatory comments. */
export declare function addDisabledRule(line: string, code: string): string | null;
export {};
