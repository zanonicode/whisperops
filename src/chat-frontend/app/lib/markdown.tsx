import type { ComponentPropsWithoutRef } from 'react';
import { PlotlyChart } from '@/components/PlotlyChart';

export function ImageDispatcher(props: ComponentPropsWithoutRef<'img'>) {
  const rawSrc = props.src ?? '';
  const { alt = '' } = props;

  const src = typeof rawSrc === 'string' ? rawSrc : '';
  if (!src) return null;

  const path = src.split('?')[0].toLowerCase();

  if (path.endsWith('.json')) {
    return <PlotlyChart url={src} />;
  }

  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt={alt}
      loading="lazy"
      className="my-3 max-w-full rounded-xl ring-1 ring-white/10"
    />
  );
}
