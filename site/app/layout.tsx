import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'TRMNL · Little Screens', description: 'A quiet home for your household screens.', robots: { index: false, follow: false }, referrer: 'no-referrer' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="en"><body>{children}</body></html>; }
