import { streamRetriesTotal } from '@/lib/metrics';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST() {
  streamRetriesTotal.add(1, { reason: 'stream_closed_no_terminal' });
  return new Response(null, { status: 204 });
}
