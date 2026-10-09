import * as LSP from 'vscode-languageserver/node';
import { TextDocument, TextEdit } from 'vscode-languageserver-textdocument';
import { ShfmtConfig } from '../config';
type FormatterOptions = {
    executablePath: string;
    cwd?: string;
};
export declare class Formatter {
    private cwd;
    executablePath: string;
    private _canFormat;
    constructor({ cwd, executablePath }: FormatterOptions);
    get canFormat(): boolean;
    format(document: TextDocument, formatOptions?: LSP.FormattingOptions | null, shfmtConfig?: ShfmtConfig | null): Promise<TextEdit[]>;
    private executeFormat;
    private getShfmtArguments;
    private runShfmt;
}
export {};
