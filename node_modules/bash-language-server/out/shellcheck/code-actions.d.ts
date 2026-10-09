import * as LSP from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';
import { Node as SyntaxNode } from 'web-tree-sitter';
import { LintingResult } from './index';
/** Add suppression actions to ShellCheck's fixes using the already analyzed tree. */
export declare function getCodeActions({ document, rootNode, result, }: {
    document: TextDocument;
    rootNode?: SyntaxNode;
    result: LintingResult;
}): Record<string, LSP.CodeAction[]>;
