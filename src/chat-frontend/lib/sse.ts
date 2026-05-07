const INACTIVITY_TIMEOUT_MS = 90_000;
const STATUS_PING_MS = 30_000;

interface SSEOptions {
  url: string;
  body: Record<string, unknown>;
  onChunk: (chunk: string) => void;
  onDone: () => void;
  onError: (error: Error) => void;
  onStatus?: (message: string) => void;
}

interface SSEConnection {
  abort: () => void;
}

export function createSSEConnection(options: SSEOptions): SSEConnection {
  const { url, body, onChunk, onDone, onError, onStatus } = options;
  const controller = new AbortController();

  const run = async () => {
    let retries = 0;
    const maxRetries = 3;

    while (retries <= maxRetries) {
      let inactivityTimer: ReturnType<typeof setTimeout> | null = null;
      let pingTimer: ReturnType<typeof setTimeout> | null = null;

      const clearTimers = () => {
        if (inactivityTimer) clearTimeout(inactivityTimer);
        if (pingTimer) clearTimeout(pingTimer);
        inactivityTimer = null;
        pingTimer = null;
      };

      const armTimers = () => {
        clearTimers();

        pingTimer = setTimeout(() => {
          onStatus?.('still thinking...');
        }, STATUS_PING_MS);

        // Inactivity timeout is separate from the retry path — a hanging agent
        // is alive but unresponsive; retrying would stack invocations on kagent.
        inactivityTimer = setTimeout(() => {
          clearTimers();
          controller.abort();
          onError(new Error('agent timeout — no response in 90s'));
        }, INACTIVITY_TIMEOUT_MS);
      };

      try {
        const response = await fetch(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Accept: 'text/event-stream',
          },
          body: JSON.stringify(body),
          signal: controller.signal,
        });

        if (!response.ok || !response.body) {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        armTimers();

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          armTimers();

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() ?? '';

          for (const line of lines) {
            if (line.startsWith('data: ')) {
              const data = line.slice(6).trim();
              if (data === '[DONE]') {
                clearTimers();
                onDone();
                return;
              }
              try {
                const parsed = JSON.parse(data);
                if (parsed.error) {
                  clearTimers();
                  onError(new Error(parsed.error));
                  return;
                }
                if (parsed.content) {
                  onChunk(parsed.content);
                }
              } catch {
                onChunk(data);
              }
            }
          }
        }

        clearTimers();
        onDone();
        return;
      } catch (err) {
        clearTimers();

        if (controller.signal.aborted) {
          onDone();
          return;
        }

        retries += 1;
        if (retries > maxRetries) {
          onError(err instanceof Error ? err : new Error(String(err)));
          return;
        }

        const delay = Math.min(1000 * 2 ** retries, 8000);
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }
  };

  run();

  return {
    abort: () => controller.abort(),
  };
}
