import { notFound } from 'next/navigation';
import { tokenOK } from '@/server/service';
import { DEFAULT_INSTRUCTIONS } from '@/server/guide';
import ScreenManager from '@/components/ScreenManager';
export const dynamic = 'force-dynamic';
export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const q = await searchParams;
  if (typeof q.token !== 'string' || !tokenOK(q.token)) notFound();
  return <ScreenManager defaultInstructions={DEFAULT_INSTRUCTIONS} />;
}
