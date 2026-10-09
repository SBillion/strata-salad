import { Node as SyntaxNode } from 'web-tree-sitter';
/** A static declaration, shared by completion and declaration lookup. */
export type VariableDeclaration = {
    name: string;
    node: SyntaxNode;
    scope: SyntaxNode;
    availableFrom: number;
};
export declare function getLocalVariableDeclarations(command: SyntaxNode): VariableDeclaration[];
/**
 * Only unconditional statements directly in the function body prove locality.
 * Conditional declarations, pipelines and runtime shell options remain unknown.
 */
export declare function getUnconditionalLocals(body: SyntaxNode): Map<string, number>;
