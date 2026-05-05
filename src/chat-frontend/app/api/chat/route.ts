import { NextRequest } from 'next/server';

const PLANNER_URL = process.env.PLANNER_URL ?? 'http://localhost:8080';

export async function POST(req: NextRequest): Promise<Response> {
  const body = await req.json();
  const { message } = body as { message: string };

  if (!message?.trim()) {
    return new Response(JSON.stringify({ error: 'message is required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    async start(controller) {
      try {
        const plannerResponse = await fetch(`${PLANNER_URL}/v1/messages`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Accept: 'text/event-stream',
          },
          body: JSON.stringify({ message, stream: true }),
        });

        if (!plannerResponse.ok || !plannerResponse.body) {
          const errorData = `data: ${JSON.stringify({ error: 'Planner unavailable' })}\n\n`;
          controller.enqueue(encoder.encode(errorData));
          controller.close();
          return;
        }

        const reader = plannerResponse.body.getReader();
        const decoder = new TextDecoder();

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          const text = decoder.decode(value, { stream: true });
          controller.enqueue(encoder.encode(text));
        }

        controller.enqueue(encoder.encode('data: [DONE]\n\n'));
        controller.close();
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : 'Unknown error';
        const errorData = `data: ${JSON.stringify({ error: errorMsg })}\n\n`;
        controller.enqueue(encoder.encode(errorData));
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    },
  });
}
