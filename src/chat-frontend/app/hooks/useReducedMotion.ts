'use client';

import { useReducedMotion as motionUseReducedMotion } from 'motion/react';

export function useReducedMotion(): boolean | null {
  return motionUseReducedMotion();
}
