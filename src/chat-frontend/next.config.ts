import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  output: 'standalone',
  experimental: {
    serverComponentsExternalPackages: [],
  },
  env: {
    NEXT_TELEMETRY_DISABLED: '1',
  },
};

export default nextConfig;
