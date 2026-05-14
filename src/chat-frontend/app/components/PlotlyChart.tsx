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

interface PlotlyChartProps {
  // Legacy network path (kept as a fallback) — the chart JSON is fetched
  // from a signed GCS URL. Subject to TTL expiration and worker URL-reuse
  // bugs; prefer `inlineJson`.
  url?: string;
  // Preferred path: chart JSON arrives inline in the SSE stream as the
  // raw stringified Plotly figure. No fetch, no TTL, no expiration class.
  inlineJson?: string;
}

export function PlotlyChart({ url, inlineJson }: PlotlyChartProps) {
  const [fig, setFig] = useState<PlotlyFigure | null>(null);
  const [err, setErr] = useState<ErrorKind>(null);
  const [errDetail, setErrDetail] = useState<string>('');

  useEffect(() => {
    let cancelled = false;

    // Inline JSON path (preferred) — synchronous parse, no network.
    if (inlineJson) {
      try {
        const json = JSON.parse(inlineJson) as PlotlyFigure;
        if (!cancelled) setFig(json);
      } catch (e) {
        const detail = e instanceof Error ? e.message : 'parse error';
        const sample = inlineJson.slice(0, 80);
        if (!cancelled) {
          setErrDetail(`${detail} — first 80 chars: ${sample}`);
          setErr('parse');
        }
      }
      return () => {
        cancelled = true;
      };
    }

    // Legacy network path.
    if (!url) {
      setErrDetail('No chart payload (neither inline JSON nor URL).');
      setErr('parse');
      return () => {
        cancelled = true;
      };
    }

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
  }, [url, inlineJson]);

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
        <div>Failed to load chart.</div>
        {errDetail && (
          <div className="mt-1 font-mono text-xs opacity-80">{errDetail}</div>
        )}
        {url && (
          <a href={url} className="underline mt-1 inline-block" target="_blank" rel="noreferrer">
            Open raw
          </a>
        )}
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
