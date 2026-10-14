import { handleAPI } from '@/server/service';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) { return handleAPI(request, ['assets', new URL(request.url).searchParams.get('id') ?? '', 'image']); }
