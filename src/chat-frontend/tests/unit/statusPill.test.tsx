import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { StatusPill } from '@/components/StatusPill';

describe('StatusPill', () => {
  it('renders nothing when not visible', () => {
    const { container } = render(<StatusPill author="planner" visible={false} />);
    expect(container.querySelector('[role="status"]')).toBeNull();
  });

  it('renders the planner label when visible', async () => {
    render(<StatusPill author="planner" visible={true} />);
    expect(await screen.findByText('Planner thinking…')).toBeInTheDocument();
  });

  it('renders the worker label for worker author', async () => {
    render(<StatusPill author="worker" visible={true} />);
    expect(await screen.findByText('Worker analysing…')).toBeInTheDocument();
  });

  it('renders Processing… for unknown author', async () => {
    render(<StatusPill author="unknown-bot" visible={true} />);
    expect(await screen.findByText('Processing…')).toBeInTheDocument();
  });

  it('has aria-live polite for SR announcement', async () => {
    render(<StatusPill author="planner" visible={true} />);
    const pill = await screen.findByRole('status');
    expect(pill).toHaveAttribute('aria-live', 'polite');
  });
});
