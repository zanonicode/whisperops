interface ChartEmbedProps {
  url: string;
  alt?: string;
}

export default function ChartEmbed({ url, alt = 'Chart' }: ChartEmbedProps) {
  const isHtml = url.toLowerCase().includes('.html') || url.includes('text/html');

  if (isHtml) {
    return (
      <div className="my-4">
        <iframe
          src={url}
          title={alt}
          className="w-full border border-gray-200 dark:border-gray-700 rounded-lg"
          style={{ height: '400px' }}
          sandbox="allow-scripts allow-same-origin"
        />
        <p className="text-xs text-gray-400 mt-1">
          <a href={url} target="_blank" rel="noreferrer" className="underline">
            Open interactive chart in new tab
          </a>
        </p>
      </div>
    );
  }

  return (
    <div className="my-4">
      <img
        src={url}
        alt={alt}
        className="max-w-full rounded-lg border border-gray-200 dark:border-gray-700"
        loading="lazy"
      />
    </div>
  );
}
