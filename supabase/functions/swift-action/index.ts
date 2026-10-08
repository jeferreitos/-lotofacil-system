import { createClient } from "npm:@supabase/supabase-js@2";

// Duas fontes com o mesmo resultado: a API oficial da Caixa e o mirror
// comunitário. Se uma estiver fora do ar (ou bloquear a origem), usa a outra.
const API_CAIXA = "https://servicebus2.caixa.gov.br/portaldeloterias/api/lotofacil";
const API_MIRROR = "https://loteriascaixa-api.herokuapp.com/api/lotofacil";

// Cabeçalhos de CORS — sem isso o navegador bloqueia a chamada feita a
// partir do front-end (jeferreitos.github.io), mesmo que a função funcione
// perfeitamente quando chamada de fora do navegador (SQL Editor, curl, etc.)
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface Concurso {
  concurso: number;
  data_sorteio: string;
  dezenas: number[];
  acumulou: boolean;
}

// datas vêm como dd/MM/yyyy nas duas APIs
function dataIso(data: string) {
  const [dd, mm, yyyy] = data.split("/");
  return `${yyyy}-${mm}-${dd}`;
}

function ordenar(dezenas: string[]) {
  return dezenas.map((d) => parseInt(d, 10)).sort((a, b) => a - b);
}

async function buscarNaCaixa(numero?: number): Promise<Concurso> {
  const res = await fetch(numero ? `${API_CAIXA}/${numero}` : API_CAIXA, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`Caixa respondeu ${res.status}`);
  const j = await res.json();
  return {
    concurso: j.numero,
    data_sorteio: dataIso(j.dataApuracao),
    dezenas: ordenar(j.listaDezenas),
    acumulou: j.acumulado ?? false,
  };
}

async function buscarNoMirror(numero?: number): Promise<Concurso> {
  const res = await fetch(`${API_MIRROR}/${numero ?? "latest"}`);
  if (!res.ok) throw new Error(`Mirror respondeu ${res.status}`);
  const j = await res.json();
  return {
    concurso: j.concurso,
    data_sorteio: dataIso(j.data),
    dezenas: ordenar(j.dezenas),
    acumulou: j.acumulou ?? false,
  };
}

// sem número = concurso mais recente
async function buscarConcurso(numero?: number): Promise<Concurso> {
  try {
    return await buscarNaCaixa(numero);
  } catch (erroCaixa) {
    try {
      return await buscarNoMirror(numero);
    } catch (erroMirror) {
      throw new Error(`${erroCaixa instanceof Error ? erroCaixa.message : erroCaixa} / ${erroMirror instanceof Error ? erroMirror.message : erroMirror}`);
    }
  }
}

Deno.serve(async (req) => {
  // O navegador manda um OPTIONS antes do POST de verdade (preflight).
  // Sem responder isso com os cabeçalhos de CORS, ele nunca chega a
  // mandar o POST.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // backfill no corpo ({"backfill": true}) ou na URL (?backfill=true)
    const corpo = await req.json().catch(() => ({}));
    const backfill = corpo?.backfill === true || corpo?.backfill === "true" ||
      new URL(req.url).searchParams.get("backfill") === "true";

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const ultimo = await buscarConcurso();

    // Concursos que já estão no banco (de 1000 em 1000: o Supabase devolve
    // no máximo 1000 linhas por consulta)
    const jaTemos = new Set<number>();
    for (let inicio = 0; ; inicio += 1000) {
      const { data, error } = await supabase
        .from("concursos")
        .select("concurso")
        .order("concurso")
        .range(inicio, inicio + 999);
      if (error) throw new Error(`Erro ao ler concursos: ${error.message}`);
      (data ?? []).forEach((r) => jaTemos.add(r.concurso));
      if (!data || data.length < 1000) break;
    }

    // Sem backfill: o que falta nos últimos 30 concursos e depois do último
    // salvo (se o cron ou uma busca falhar um dia, a execução seguinte
    // recupera). Com backfill: todos os buracos do histórico. Concurso já
    // salvo não é baixado de novo.
    const maiorSalvo = jaTemos.size > 0 ? Math.max(...jaTemos) : 0;
    const inicio = backfill ? 1 : Math.max(1, maiorSalvo - 30);
    const faltando: number[] = [];
    for (let n = inicio; n <= ultimo.concurso; n++) {
      if (!jaTemos.has(n)) faltando.push(n);
    }

    const salvos: number[] = [];
    const falhas: number[] = [];
    let pendentes: Concurso[] = [];

    const gravar = async () => {
      if (pendentes.length === 0) return;
      const { error } = await supabase.from("concursos").upsert(pendentes, { onConflict: "concurso" });
      if (error) throw new Error(`Erro ao salvar concursos: ${error.message} | ${error.details ?? ""} | ${error.hint ?? ""}`);
      salvos.push(...pendentes.map((c) => c.concurso));
      pendentes = [];
    };

    const TAMANHO_LOTE = 10;
    for (let i = 0; i < faltando.length; i += TAMANHO_LOTE) {
      const lote = faltando.slice(i, i + TAMANHO_LOTE);
      const resultados = await Promise.all(
        lote.map(async (n) => {
          if (n === ultimo.concurso) return ultimo;
          try {
            return await buscarConcurso(n);
          } catch {
            falhas.push(n);
            return null;
          }
        }),
      );
      pendentes.push(...resultados.filter((r): r is Concurso => r !== null));

      // salva em blocos, pra não perder tudo se der timeout no meio do caminho
      if (pendentes.length >= 200) await gravar();

      // pequena pausa pra não sobrecarregar as APIs
      if (i + TAMANHO_LOTE < faltando.length) await new Promise((r) => setTimeout(r, 300));
    }
    await gravar();

    if (salvos.length > 0) {
      const { error: rpcErr } = await supabase.rpc("recalcular_ciclos");
      if (rpcErr) throw new Error(`Erro ao recalcular ciclos: ${rpcErr.message} | ${rpcErr.details ?? ""} | ${rpcErr.hint ?? ""}`);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        ultimo_disponivel: ultimo.concurso,
        importados: salvos.length, // quantos foram salvos de fato
        concursos_importados: salvos.sort((a, b) => a - b),
        falhas: falhas.sort((a, b) => a - b),
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : JSON.stringify(err);
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
