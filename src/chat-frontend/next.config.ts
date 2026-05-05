import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  output: 'standalone',
  env: {
    NEXT_TELEMETRY_DISABLED: '1',
  },
};

export default nextConfig;
