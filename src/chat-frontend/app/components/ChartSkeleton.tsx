export function ChartSkeleton() {
  return (
    <div
      className="my-3 overflow-hidden rounded-xl ring-1 ring-white/10 bg-white/[0.02]"
      style={{ aspectRatio: '16/9' }}
      role="status"
      aria-label="Loading chart"
    >
      <div className="h-full w-full animate-pulse bg-white/[0.03]" />
    </div>
  );
}
