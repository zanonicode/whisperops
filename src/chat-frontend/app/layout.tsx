import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Dataset Whisperer',
  description: 'Conversational data analysis powered by per-tenant AI agents',
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
