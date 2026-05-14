import { describe, it, expect, vi } from 'vitest';
import { render } from '@testing-library/react';

vi.mock('@/components/PlotlyChart', () => ({
  PlotlyChart: ({ url }: { url: string }) => <div data-testid="plotly-chart" data-url={url} />,
}));

import { ImageDispatcher } from '@/lib/markdown';

describe('ImageDispatcher', () => {
  it('renders PlotlyChart for .json URLs', () => {
    const { getByTestId } = render(
      <ImageDispatcher src="https://storage.example.com/charts/foo.json?sig=abc" alt="chart" />
    );
    expect(getByTestId('plotly-chart')).toBeInTheDocument();
  });

  it('renders img for .png URLs', () => {
    const { getByRole } = render(
      <ImageDispatcher src="https://storage.example.com/charts/bar.png" alt="plot" />
    );
    expect(getByRole('img')).toBeInTheDocument();
  });

  it('renders img for .png URLs with query params', () => {
    const { getByRole } = render(
      <ImageDispatcher src="https://storage.example.com/charts/bar.png?sig=xyz" alt="plot" />
    );
    expect(getByRole('img')).toBeInTheDocument();
  });

  it('renders null for empty src', () => {
    const { container } = render(<ImageDispatcher src="" alt="" />);
    expect(container.firstChild).toBeNull();
  });

  it('passes full URL (with query) to PlotlyChart', () => {
    const url = 'https://storage.example.com/charts/data.json?sig=test';
    const { getByTestId } = render(<ImageDispatcher src={url} alt="data" />);
    expect(getByTestId('plotly-chart').getAttribute('data-url')).toBe(url);
  });
});
