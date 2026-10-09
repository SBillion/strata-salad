export declare function untildify(pathWithTilde: string): string;
export declare function getFilePaths({ globPattern, rootPath, maxItems, maxDirectories, timeoutMs, ignore, skipHiddenEntries, signal, onLimit, }: {
    globPattern: string;
    rootPath: string;
    maxItems: number;
    maxDirectories?: number;
    timeoutMs?: number;
    ignore?: string[];
    skipHiddenEntries?: boolean;
    signal?: AbortSignal;
    onLimit?: (reason: 'directories' | 'time') => void;
}): Promise<string[]>;
