import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="flex h-screen flex-col items-center justify-center gap-4 bg-background text-center">
      <h2 className="text-2xl font-semibold text-foreground">404</h2>
      <p className="text-sm text-muted-foreground">This page could not be found.</p>
      <Link
        href="/"
        className="rounded-md bg-accent px-4 py-2 text-sm font-medium text-accent-foreground hover:bg-accent/90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        Go home
      </Link>
    </div>
  );
}
