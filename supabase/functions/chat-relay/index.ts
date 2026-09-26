// The chat-relay Edge Function — Docs/PLANNING.md §59.6's contract implemented. Designed as a
// near-transparent proxy: the request/response body is passed through to/from OpenAI unchanged,
// so OpenAIClient.swift's request-building and response-parsing need no changes beyond pointing
// at this URL with a Supabase session token instead of an OpenAI key.
//
// Flow: verify the caller's Supabase session -> look up their plan + current-period spend ->
// reject if a conservative pre-check estimate would exceed their cap -> relay to OpenAI with
// this function's own key -> log the *actual* cost from OpenAI's own usage field -> return the
// response verbatim.

import { createClient } from "jsr:@supabase/supabase-js@2";

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";

// Conservative pre-check estimates in cents, from Docs/PLANNING.md §52's cost bands — used only
// to gate BEFORE the real call. The actual cost logged afterward comes from OpenAI's own
// `usage` field, not this estimate.
const ESTIMATED_COST_CENTS: Record<string, number> = {
  fast_path: 5, // ~$0.05 upper bound for a 256-max-token classification call
  agentic: 50, // ~$0.50 upper bound for a 1024-max-token agentic-loop turn
};

// gpt-5.4-mini Standard pricing, confirmed directly against OpenAI's own pricing docs
// (developers.openai.com/api/docs/pricing, Sept 2026): $0.75/M input tokens, $4.50/M output
// tokens -> converted to cents/token below. Treats every prompt token at the non-cached rate
// ($0.75/M) even though OpenAI charges cached input at 10x less ($0.075/M, exposed as
// usage.prompt_tokens_details.cached_tokens in the response) — a known simplification, not
// currently split out, that only ever over-estimates cost (errs toward stricter budget
// enforcement, never under-charges). Revisit if fast-path calls start reliably hitting the
// prompt cache in practice.
const PROMPT_TOKEN_COST_CENTS = 0.000075;
const COMPLETION_TOKEN_COST_CENTS = 0.00045;

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: { message: "Method not allowed", type: "invalid_request_error" } }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) {
    return jsonResponse(
      { error: { message: "No auth token provided.", type: "invalid_request_error" } },
      401,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const openaiKey = Deno.env.get("OPENAI_API_KEY")!;

  // Two clients, deliberately: one scoped to the caller's own token (only enough privilege to
  // confirm who they are), one with the service role (the only thing allowed to write
  // usage_events — RLS blocks that from the caller's own token by design, see the migration).
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse(
      { error: { message: "Invalid or expired session.", type: "invalid_request_error" } },
      401,
    );
  }
  const userId = userData.user.id;

  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const { data: profile, error: profileError } = await adminClient
    .from("profiles")
    .select("monthly_cap_cents")
    .eq("id", userId)
    .single();
  if (profileError || !profile) {
    return jsonResponse(
      { error: { message: "No account profile found.", type: "invalid_request_error" } },
      400,
    );
  }

  const { data: usage } = await adminClient
    .from("current_period_usage")
    .select("spent_cents")
    .eq("user_id", userId)
    .maybeSingle();
  const spentCents = usage?.spent_cents ?? 0;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: { message: "Malformed JSON body.", type: "invalid_request_error" } }, 400);
  }

  // Mirrors OpenAIClient.swift's own split: 256 max tokens for the fast-path classifier, 1024
  // for an agentic-loop turn (see classifyFastPathIntent/sendAgenticTurn).
  const maxTokens = typeof body.max_completion_tokens === "number" ? body.max_completion_tokens : 0;
  const requestKind = maxTokens > 512 ? "agentic" : "fast_path";
  const estimatedCents = ESTIMATED_COST_CENTS[requestKind];

  if (spentCents + estimatedCents > Number(profile.monthly_cap_cents)) {
    return jsonResponse(
      { error: { message: "Monthly usage limit reached for your plan.", type: "budget_exceeded" } },
      402,
    );
  }

  // Relayed verbatim — no reshaping of the request body at all (Docs/PLANNING.md §59.6).
  const openaiResponse = await fetch(OPENAI_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${openaiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const responseJson = await openaiResponse.json();

  if (openaiResponse.ok && responseJson.usage) {
    const promptTokens = responseJson.usage.prompt_tokens ?? 0;
    const completionTokens = responseJson.usage.completion_tokens ?? 0;
    const actualCostCents =
      promptTokens * PROMPT_TOKEN_COST_CENTS + completionTokens * COMPLETION_TOKEN_COST_CENTS;

    await adminClient.from("usage_events").insert({
      user_id: userId,
      request_kind: requestKind,
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      cost_cents: actualCostCents,
    });
  }

  return jsonResponse(responseJson, openaiResponse.status);
});
