'use client';

import dynamic from 'next/dynamic';
import { useEffect, useState } from 'react';
import { ChartSkeleton } from './ChartSkeleton';

const Plot = dynamic(() => import('react-plotly.js') as never, {
  ssr: false,
  loading: () => <ChartSkeleton />,
}) as React.ComponentType<{
  data: unknown[];
  layout?: unknown;
  config?: unknown;
  useResizeHandler?: boolean;
  style?: React.CSSProperties;
}>;

import type React from 'react';

type PlotlyFigure = {
  data: unknown[];
  layout?: Record<string, unknown>;
  config?: Record<string, unknown>;
};

type ErrorKind = 'expired' | 'parse' | 'fetch' | null;

export function PlotlyChart({ url }: { url: string }) {
  const [fig, setFig] = useState<PlotlyFigure | null>(null);
  const [err, setErr] = useState<ErrorKind>(null);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const res = await fetch(url);
        if (res.status === 403 || res.status === 410) {
          if (!cancelled) setErr('expired');
          return;
        }
        if (!res.ok) {
          if (!cancelled) setErr('fetch');
          return;
        }
        const json = (await res.json()) as PlotlyFigure;
        if (!cancelled) setFig(json);
      } catch {
        if (!cancelled) setErr('parse');
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [url]);

  if (err === 'expired') {
    return (
      <div
        className="my-3 rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 text-sm text-amber-300"
        role="alert"
      >
        Chart link expired — please re-ask the question to regenerate.
      </div>
    );
  }

  if (err) {
    return (
      <div
        className="my-3 rounded-lg border border-red-500/30 bg-red-500/5 p-3 text-sm text-red-300"
        role="alert"
      >
        Failed to load chart.{' '}
        <a href={url} className="underline" target="_blank" rel="noreferrer">
          Open raw
        </a>
      </div>
    );
  }

  if (!fig) return <ChartSkeleton />;

  return (
    <div className="my-3 overflow-hidden rounded-xl ring-1 ring-white/10 bg-black/20">
      <Plot
        data={fig.data}
        layout={{
          ...fig.layout,
          autosize: true,
          paper_bgcolor: 'rgba(0,0,0,0)',
          plot_bgcolor: 'rgba(0,0,0,0)',
        }}
        config={{
          displaylogo: false,
          responsive: true,
          ...(fig.config ?? {}),
        }}
        useResizeHandler
        style={{ width: '100%', height: 360 }}
      />
    </div>
  );
}
