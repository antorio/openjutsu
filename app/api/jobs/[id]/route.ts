import { apiAccess, HttpError } from "../../../../lib/http.ts";
import { NextResponse } from "next/server";
import { NotFound } from "@comfyorg/sdk";
import { getJob, publicJob } from "../../../../lib/comfy.ts";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// The progress view polls this alongside the event stream, which some tunnels do not carry. The proxy forgets jobs when
// it restarts; 404 tells the page the job is no longer available, as the event stream's "expired" does.
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = apiAccess(request);
  if (denied) return denied;
  try {
    const { id } = await params;
    return NextResponse.json(publicJob(await getJob(id)), { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof NotFound) return NextResponse.json({ error: "This job is no longer available." }, { status: 404 });
    return NextResponse.json({ error: error instanceof Error ? error.message : "Unable to check the job." }, { status: error instanceof HttpError ? error.status : 502 });
  }
}

export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = apiAccess(request);
  if (denied) return denied;
  try {
    const { id } = await params;
    const job = await getJob(id);
    return NextResponse.json(publicJob(await job.cancel()));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Unable to cancel the job." }, { status: error instanceof HttpError ? error.status : 502 });
  }
}
