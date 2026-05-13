/**
 * Memory policy constants.
 *
 * All memory-system thresholds live here so they compile into the binary
 * and cannot drift out of sync with the code. There is no config file or
 * database reload path -- change these constants, rebuild, redeploy.
 *
 * Slice: 001-memory-policy-enforcement
 */

export const MEMORY_POLICY = {
  /** New memories are pinned by default so they never decay. */
  pinByDefault: true,

  /**
   * Cosine similarity above this threshold means "duplicate -- supersede".
   * Lowered from 0.85 to 0.78 to catch near-duplicates that were slipping
   * through (e.g. memory #142 vs #166 restating the same fact).
   */
  cosineThreshold: 0.78,

  /**
   * When cosine falls in the ambiguous zone (cosineJaccardZone .. cosineThreshold),
   * we additionally check topic-set Jaccard overlap. If Jaccard >= this value,
   * treat as duplicate.
   */
  jaccardFallback: 0.6,

  /**
   * Lower bound of the "ambiguous zone" where Jaccard fallback kicks in.
   * Below this cosine value we consider the memories distinct regardless of
   * topic overlap.
   */
  cosineJaccardZone: 0.65,

  /** How often the prune script should run (in days). */
  pruneIntervalDays: 7,

  /**
   * Maximum supersession chain depth. If a new memory would create a chain
   * longer than this, we mark all prior entries as low-importance and only
   * keep the newest.
   */
  maxSupersessionDepth: 5,
} as const;

/**
 * Jaccard similarity between two sets (represented as string arrays).
 * Returns 0-1; 0 when no overlap, 1 when identical sets.
 */
export function topicJaccard(a: string[], b: string[]): number {
  if (a.length === 0 && b.length === 0) return 0;
  const setA = new Set(a.map((s) => s.toLowerCase().trim()));
  const setB = new Set(b.map((s) => s.toLowerCase().trim()));
  let intersection = 0;
  for (const item of setA) {
    if (setB.has(item)) intersection++;
  }
  const union = new Set([...setA, ...setB]).size;
  return union === 0 ? 0 : intersection / union;
}
