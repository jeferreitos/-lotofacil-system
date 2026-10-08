import { createClient } from "npm:@supabase/supabase-js@2";

const API_BASE = "https://loteriascaixa-api.herokuapp.com/api/lotofacil";

// Cabeçalhos de CORS — sem isso o navegador bloqueia a chamada feita a
// partir do front-end (jeferreitos.github.io), mesmo que a função funcione
// perfeitamente quando chamada de fora do navegador (SQL Editor, curl, etc.)
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface ResultadoCaixa {
  concurso: number;
  data: string;
  dezenas: string[];
  acumulou?: boolean;
}

function normalizar(json: ResultadoCaixa) {
  const [dd, mm, yyyy] = json.data.split("/");
  return {
    concurso: json.concurso,
    data_sorteio: `${yyyy}-${mm}-${dd}`,
    dezenas: json.dezenas.map((d) => parseInt(d, 10)),
    acumulou: json.acumulou ?? false,
  };
}

Deno.serve(async (req) => {
  // O navegador manda um OPTIONS antes do POST de verdade (preflight).
  // Sem responder isso com os cabeçalhos de CORS, ele nunca chega a
  // mandar o POST — foi exatamente o que estava bloqueando o botão.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { backfill } = await req.json().catch(() => ({ backfill: false }));

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const latestRes = await fetch(`${API_BASE}/latest`);
    if (!latestRes.ok) throw new Error(`Falha ao buscar 'latest': ${latestRes.status}`);
    const latestJson: ResultadoCaixa = await latestRes.json();
    const ultimoDisponivel = latestJson.concurso;

    let lista: number[] = [ultimoDisponivel];

    if (backfill) {
      lista = [];
      for (let c = 1; c <= ultimoDisponivel; c++) lista.push(c);
    }

    const resultados: ReturnType<typeof normalizar>[] = [];
    const TAMANHO_LOTE = 10;

    for (let i = 0; i < lista.length; i += TAMANHO_LOTE) {
      const lote = lista.slice(i, i + TAMANHO_LOTE);
      const respostas = await Promise.all(
        lote.map(async (concurso) => {
          const url = concurso === ultimoDisponivel ? `${API_BASE}/latest` : `${API_BASE}/${concurso}`;
          const res = await fetch(url);
          if (!res.ok) return null;
          const json: ResultadoCaixa = await res.json();
          return normalizar(json);
        }),
      );
      resultados.push(...respostas.filter((r): r is ReturnType<typeof normalizar> => r !== null));

      // salva em blocos, pra não perder tudo se der timeout no meio do caminho
      if (resultados.length >= 200) {
        const { error: upsertErr } = await supabase
          .from("concursos")
          .upsert(resultados.splice(0, resultados.length), { onConflict: "concurso" });
        if (upsertErr) throw new Error(`Erro ao salvar concursos: ${upsertErr.message}`);
      }

      if (i + TAMANHO_LOTE < lista.length) await new Promise((r) => setTimeout(r, 300));
    }

    if (resultados.length > 0) {
      const { error: upsertErr } = await supabase
        .from("concursos")
        .upsert(resultados, { onConflict: "concurso" });
      if (upsertErr) throw new Error(`Erro ao salvar concursos: ${upsertErr.message} | ${upsertErr.details ?? ""} | ${upsertErr.hint ?? ""}`);
    }

    const { error: rpcErr } = await supabase.rpc("recalcular_ciclos");
    if (rpcErr) throw new Error(`Erro ao recalcular ciclos: ${rpcErr.message} | ${rpcErr.details ?? ""} | ${rpcErr.hint ?? ""}`);

    return new Response(JSON.stringify({ importados: lista.length }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : JSON.stringify(err);
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});