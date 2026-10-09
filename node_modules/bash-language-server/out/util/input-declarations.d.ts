import * as LSP from 'vscode-languageserver/node';
import { Node as SyntaxNode } from 'web-tree-sitter';
import { VariableDeclaration } from './variable-declarations';
type InputDeclaration = VariableDeclaration & {
    range: LSP.Range;
};
/** Literal destinations only: no implicit REPLY/MAPFILE or runtime word expansion. */
export declare function getInputVariableDeclarations(command: SyntaxNode): InputDeclaration[];
export declare function getInputVariableDeclaration(node: SyntaxNode): InputDeclaration | undefined;
export declare function variableNameRange(node: SyntaxNode): LSP.Range;
export {};
