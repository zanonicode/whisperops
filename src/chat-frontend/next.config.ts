import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  output: 'standalone',
  env: {
    NEXT_TELEMETRY_DISABLED: '1',
  },
  serverExternalPackages: ['@opentelemetry/sdk-node', '@opentelemetry/instrumentation'],
};

export default nextConfig;
