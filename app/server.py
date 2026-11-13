# -*- coding: utf-8 -*-
"""
Servidor local da auditoria fiscal de estoque.

Le os dados do Supabase (projeto ccquyncwgtszhicicvye) e serve o painel.
O token NUNCA vai para o browser: fica so aqui no servidor.

Token: variavel de ambiente SBT, ou arquivo .env na pasta pai com SBT=...
Uso:   python server.py [porta]
"""
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
PROJECT_REF = "ccquyncwgtszhicicvye"
API = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
CACHE_TTL = 30          # segundos
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8777


def load_token():
    tok = os.environ.get("SBT", "").strip()
    if tok:
        return tok
    for env in (os.path.join(HERE, ".env"), os.path.join(os.path.dirname(HERE), ".env")):
        if os.path.exists(env):
            for line in open(env, encoding="utf-8"):
                m = re.match(r"\s*(?:export\s+)?SBT\s*=\s*(.+)", line)
                if m:
                    return m.group(1).strip().strip('"').strip("'")
    sys.exit("ERRO: token nao encontrado. Defina SBT no ambiente ou em um arquivo .env")


TOKEN = load_token()
_cache = {}


def query(sql):
    """Consulta o Postgres via Management API. Usa curl: o urllib e barrado pelo Cloudflare."""
    now = time.time()
    hit = _cache.get(sql)
    if hit and now - hit[0] < CACHE_TTL:
        return hit[1]
    # payload por stdin: com arquivo temporario fixo, chamadas concorrentes
    # sobrescreviam o payload umas das outras e o curl mandava a query errada.
    p = subprocess.run(
        ["curl", "-s", "-m", "60", "-X", "POST", API,
         "-H", f"Authorization: Bearer {TOKEN}",
         "-H", "Content-Type: application/json",
         "--data-binary", "@-",
         "-w", "\n__HTTP__%{http_code}"],
        input=json.dumps({"query": sql}),
        capture_output=True, text=True, encoding="utf-8")
    body, _, code = p.stdout.rpartition("__HTTP__")
    body = body.strip()
    if code.strip() not in ("200", "201"):
        raise RuntimeError(f"HTTP {code.strip()}: {body[:300]}")
    data = json.loads(body) if body else []
    _cache[sql] = (now, data)
    return data


# ------------------------------------------------------------------ consultas
SQL_KPIS = """
select
  (select count(*) from inventario_item)                       as itens,
  (select sum(qtd) from inventario_item)                       as unidades,
  (select sum(vl_item) from inventario_item)                   as valor,
  (select count(*) from estabelecimento)                       as filiais,
  (select count(*) from sped_arquivo)                          as arquivos,
  (select count(*) from doc_fiscal)                            as documentos,
  (select count(*) from inventario_item where qtd < 0)         as negativos,
  (select count(*) from v_custo_inventario_vs_entrada)         as div_itens,
  (select coalesce(sum(exposicao),0)
     from v_custo_inventario_vs_entrada)                       as div_exposicao,
  (select coalesce(sum(vl_item),0) from inventario_item
     where ind_prop = '1')                                     as em_terceiros,
  (select count(*) from v_inventario_conferencia
     where abs(diferenca) < 0.005)                             as conf_ok,
  (select count(*) from v_inventario_conferencia)              as conf_total,
  (select max(dt_inv)::text from inventario)                   as data_base
"""

SQL_FILIAIS = """
select c.uf, c.cnpj, e.nome, c.qtd_itens, c.qtd_total, c.vl_somado_h010 as valor,
       c.vl_declarado_h005 as declarado, c.diferenca
from v_inventario_conferencia c
join estabelecimento e on e.cnpj = c.cnpj
order by c.vl_somado_h010 desc
"""

SQL_DIVERG = """
select uf, cod_item, descr_item, qtd, custo_inventario, custo_entrada, multiplo, exposicao
from v_custo_inventario_vs_entrada order by exposicao desc
"""

SQL_TERCEIROS = """
select uf, cnpj, depositario, count(*) as itens, sum(vl_item) as valor
from v_inventario where ind_prop = '1'
group by uf, cnpj, depositario order by valor desc
"""

SQL_TOP = """
select uf, cod_item, descr_item, qtd, vl_unit, vl_item
from v_inventario order by vl_item desc limit 12
"""


def sql_kardex(cnpj, cod_item, ate):
    lim = lambda v: str(v).replace("'", "")[:44]
    ate_sql = f"date '{lim(ate)}'" if ate else "null"
    return (f"select * from kardex_item('{lim(cnpj)}', '{lim(cod_item)}', {ate_sql})")


def sql_estoque(data, uf, termo, limit, offset, ordem, situacao=""):
    d = data.replace("'", "")
    # "negativo" e o unico filtro que precisa enxergar saldo <= 0; os demais
    # ignoram itens zerados, que so poluem a lista.
    w = ["qtd < 0"] if situacao == "negativo" else ["qtd <> 0"]
    if situacao == "terceiros":
        w.append("qtd_terceiros <> 0")
    elif situacao == "proprio":
        w.append("qtd_proprio <> 0")
    if uf in ("SP", "CE", "SC"):
        w.append(f"uf = '{uf}'")
    if termo:
        w.append("busca like '%" + termo.replace("'", "''").upper() + "%'")
    cols = {"valor": "valor desc", "qtd": "qtd desc",
            "custo": "custo_medio desc", "codigo": "cod_item"}
    return (f"select *, count(*) over() as total_geral "
            f"from estoque_em_detalhe(date '{d}') where {' and '.join(w)} "
            f"order by {cols.get(ordem, 'valor desc')} "
            f"limit {int(limit)} offset {int(offset)}")


def _mes(v, padrao):
    """Aceita 'AAAA-MM' ou data completa. Devolve o primeiro e o ultimo dia."""
    v = str(v or padrao).replace("'", "")[:10]
    ano_mes = v[:7]
    if not re.match(r"^\d{4}-(0[1-9]|1[0-2])$", ano_mes):
        ano_mes = padrao
    return (f"(date '{ano_mes}-01')",
            f"(date '{ano_mes}-01' + interval '1 month - 1 day')::date")


def sql_periodo(mes, uf, termo, limit, offset, ordem, situacao="", origem="nfe"):
    ini, fim = _mes(mes, "2023-01")
    org = origem if origem in ("nfe", "") else "nfe"
    # Aqui nao se descarta item de saldo zero: entrou 10 e saiu 10 e movimento do
    # mes, e some se filtrado como na posicao acumulada.
    w = ["1=1"]
    if situacao == "negativo":
        w = ["saldo_qtd < 0"]
    elif situacao == "positivo":
        w = ["saldo_qtd > 0"]
    elif situacao == "zerado":
        w = ["saldo_qtd = 0"]
    elif situacao == "sem_custo":
        w = ["sem_custo"]
    elif situacao == "so_entrada":
        w = ["qtd_entrada > 0 and qtd_saida = 0"]
    elif situacao == "so_saida":
        w = ["qtd_saida > 0 and qtd_entrada = 0"]
    if uf in ("SP", "CE", "SC"):
        w.append(f"uf = '{uf}'")
    if termo:
        w.append("busca like '%" + termo.replace("'", "''").upper() + "%'")
    cols = {"valor": "abs(valor) desc", "saldo": "saldo_qtd",
            "entrada": "qtd_entrada desc", "saida": "qtd_saida desc",
            "codigo": "cod_item"}
    return (f"select *, count(*) over() as total_geral "
            f"from estoque_periodo_detalhe({ini}, {fim}, '{org}') "
            f"where {' and '.join(w)} "
            f"order by {cols.get(ordem, 'abs(valor) desc')} nulls last "
            f"limit {int(limit)} offset {int(offset)}")


def _cnpj_da_uf(uf):
    """Filial escolhida na tela. Sem filial, o grupo consolidado (null)."""
    return (f"(select cnpj from estabelecimento where uf = '{uf}' limit 1)"
            if uf in ("SP", "CE", "SC") else "null")


def sql_faturamento(mes, uf, funcao="faturamento_periodo"):
    ini, fim = _mes(mes, "2023-01")
    return f"select * from {funcao}({ini}, {fim}, {_cnpj_da_uf(uf)})"


def apuracao(qs):
    """
    As duas pontas da apuração de um mês: recalculado pelos XML e declarado na
    EFD. ICMS, ST, DIFAL e IPI são da filial; os federais, da empresa.
    """
    mes = (qs.get("mes") or [""])[0]
    uf = (qs.get("uf") or ["SP"])[0]
    uf = uf if uf in ("SP", "CE", "SC") else "SP"
    ini, fim = _mes(mes, "2026-07")
    cnpj = _cnpj_da_uf(uf)
    return {
        "uf": uf,
        "calculada": query(f"select * from apuracao_calculada({ini}, {fim}, {cnpj})"),
        "declarada": query(f"select * from apuracao_declarada({ini}, {fim}, {cnpj})"),
        "federal": query(f"select * from apuracao_federal_calculada({ini}, {fim})"),
    }


def resultado(qs):
    """
    Resultado contábil pela ECD. Sem período na consulta, usa tudo o que as
    ECDs vigentes cobrem.
    """
    arqs = query("select id, cnpj, nome, dt_ini::text dt_ini, dt_fin::text dt_fin, "
                 "nome_arquivo, problemas from ecd_arquivo where vigente order by dt_ini")
    if not arqs:
        return {"arquivos": [], "mensal": [], "dre": [], "receita": [], "contas_receita": []}
    ini_q, fim_q = (qs.get("ini") or [""])[0], (qs.get("fim") or [""])[0]
    ini = (f"date '{ini_q[:7]}-01'" if re.match(r"^\d{4}-\d{2}", ini_q)
           else f"date '{arqs[0]['dt_ini']}'")
    fim = (f"(date '{fim_q[:7]}-01' + interval '1 month - 1 day')::date"
           if re.match(r"^\d{4}-\d{2}", fim_q) else f"date '{arqs[-1]['dt_fin']}'")
    return {
        "arquivos": arqs,
        "mensal": query(f"select mes::text, receitas, custos_despesas, resultado, contas "
                        f"from ecd_resultado_mensal({ini}, {fim})"),
        "dre": query(f"select * from ecd_dre({ini}, {fim})"),
        "receita": query(f"select mes::text, receita_contabil, faturamento_notas, diferenca "
                         f"from confronto_receita({ini}, {fim})"),
        "contas_receita": query("select * from ecd_contas_receita_venda()"),
    }


def apuracao_consistencia(qs):
    """Cada EFD vigente conferida contra ela mesma: E110/E520 contra o C190."""
    arqs = query("select id, cnpj, uf, dt_ini::text dt_ini, dt_fin::text dt_fin, "
                 "nome_arquivo, (select count(*) from efd_apuracao a "
                 "where a.arquivo_id = s.id) as tem_bloco_e "
                 "from sped_arquivo s where vigente order by dt_ini desc, uf")
    for a in arqs:
        a["verificacoes"] = (query(f"select * from consistencia_efd({int(a['id'])})")
                             if int(a["tem_bloco_e"]) else [])
    return arqs


def sql_periodo_bloqueios(mes):
    ini, fim = _mes(mes, "2023-01")
    return f"select * from periodo_bloqueios({ini}, {fim})"


LIMITE_EXPORTACAO = 20000


def exportar(body):
    """
    Exporta em .xlsx ou .pdf a tabela que está na tela, com as colunas que o
    usuário marcou.

    As linhas vêm do navegador, e não de uma consulta refeita aqui: o que sai
    no arquivo é exatamente o que está sendo visto, com o mesmo filtro e a
    mesma ordem. Refazer a consulta no servidor abriria espaço para o relatório
    discordar da tela — e é a tela que a pessoa conferiu.
    """
    _sobe_auditoria()
    import base64
    from auditoria import exporta

    b = body or {}
    formato = (b.get("formato") or "xlsx").lower()
    if formato not in ("xlsx", "pdf"):
        return {"erro": "formato deve ser xlsx ou pdf"}
    colunas = [c for c in (b.get("colunas") or []) if c.get("campo")]
    linhas = b.get("linhas") or []
    if not colunas:
        return {"erro": "marque ao menos uma coluna"}
    if len(linhas) > LIMITE_EXPORTACAO:
        return {"erro": f"são {len(linhas)} linhas; o limite da exportação é "
                        f"{LIMITE_EXPORTACAO}. Filtre antes de exportar."}
    titulo = (b.get("titulo") or "Relatório").strip()[:120]
    sub = (b.get("subtitulo") or "").strip()[:300]

    dados = (exporta.xlsx(titulo, colunas, linhas, b.get("aba") or "Relatório", sub)
             if formato == "xlsx" else exporta.pdf(titulo, sub, colunas, linhas))
    return {"nome": exporta.nome_arquivo(titulo, formato),
            "tipo": ("application/vnd.openxmlformats-officedocument."
                     "spreadsheetml.sheet" if formato == "xlsx" else "application/pdf"),
            "base64": base64.b64encode(dados).decode(), "linhas": len(linhas)}


def erp_arquivos(qs):
    """Extratos do ERP já importados, do mais recente para o mais antigo."""
    return query(
        "select id, nome_arquivo, deposito, cnpj, uf, dt_ini::text dt_ini, "
        "       dt_fin::text dt_fin, linhas, itens, movimentos, aberturas, vigente, "
        "       problemas, importado_por, to_char(importado_em,'DD/MM/YYYY HH24:MI') importado "
        "from erp_extrato_arquivo where completo "
        "order by dt_ini desc, importado_em desc")


# --------------------------------------------------- estoque real (Kardex ERP)
def _real_arquivo(qs):
    """O extrato a analisar: o pedido, ou o vigente de período mais longo."""
    aid = int((qs.get("id") or ["0"])[0] or 0)
    if not aid:
        r = query("select id from erp_extrato_arquivo where vigente and completo "
                  "order by (dt_fin - dt_ini) desc, id desc limit 1")
        aid = int(r[0]["id"]) if r else 0
    if aid:
        # A base do cálculo é guardada; na primeira vez ela é montada aqui.
        sql = f"select erp_real_pronto({aid}) p"
        if not query(sql)[0]["p"]:
            query(f"select erp_real_prepara({aid}) n")
            _cache.pop(sql, None)
    return aid


def real_resumo(qs):
    """Os extratos disponíveis e os números do topo da tela Estoque real."""
    arqs = query(
        "select id, nome_arquivo, deposito, uf, cnpj, dt_ini::text dt_ini, "
        "       dt_fin::text dt_fin, linhas, itens, aberturas, vigente, problemas "
        "from erp_extrato_arquivo where completo "
        "order by (dt_fin - dt_ini) desc, id desc")
    aid = _real_arquivo(qs)
    if not aid:
        return {"arquivos": arqs, "arquivo": None, "resumo": None}
    r = query(f"select erp_real_resumo({aid}) r")[0]["r"]
    return {"arquivos": arqs,
            "arquivo": next((a for a in arqs if int(a["id"]) == aid), None),
            "resumo": json.loads(r) if isinstance(r, str) else r}


def _real_lista(funcao):
    def rota(qs):
        aid = _real_arquivo(qs)
        return query(f"select * from {funcao}({aid})") if aid else []
    return rota


def real_kardex(qs):
    """Os movimentos de um produto, com o saldo corrido — o detalhe da linha."""
    aid = _real_arquivo(qs)
    lit = lambda k: "'" + (qs.get(k) or [""])[0].replace("'", "''") + "'"
    if not aid:
        return []
    return query(
        "select seq, dt, hora, doc_texto, tipo, natureza, entidade, ent, sai, "
        "       saldo, saldo_impresso, fora, custo_entrada "
        f"from erp_real_linha where arquivo_id = {aid} "
        f"and cod_item = {lit('cod')} and descr_item = {lit('descr')} order by seq")


def erp_saldos(qs):
    """Fotos do saldo do ERP já importadas, da mais recente para a mais antiga."""
    return query(
        "select id, nome_arquivo, deposito, cnpj, uf, dt::text dt, linhas, itens, "
        "       quantidade, vigente, problemas, importado_por, "
        "       to_char(importado_em,'DD/MM/YYYY HH24:MI') importado "
        "from erp_saldo_arquivo order by dt desc, importado_em desc")


def erp_saldo(qs):
    """A foto do saldo do ERP contra a nossa posição na mesma data."""
    aid = int((qs.get("id") or ["0"])[0] or 0)
    if not aid:
        ultimo = query("select id from erp_saldo_arquivo "
                       "where vigente order by dt desc, id desc limit 1")
        if not ultimo:
            return {"arquivo": None, "resumo": None, "itens": [], "posicao": []}
        aid = int(ultimo[0]["id"])
    arq = query("select id, nome_arquivo, deposito, cnpj, uf, dt::text dt, linhas, "
                "itens, quantidade, vigente, problemas "
                "from erp_saldo_arquivo where id = %d" % aid)
    if not arq:
        return {"erro": "saldo não encontrado"}
    resumo = query(f"select *, dt::text dt_txt from erp_saldo_resumo({aid})")
    return {
        "arquivo": arq[0],
        "resumo": resumo[0] if resumo else None,
        "itens": query(f"select *, ultima_mov::text ultima_mov_txt "
                       f"from erp_saldo_confronto({aid})"),
        # A foto sozinha, valorada: só o que o ERP declara, sem a nossa posição.
        "posicao": query(f"select *, custo_dt::text custo_dt_txt "
                         f"from erp_saldo_valorado({aid})"),
    }


def erp_confronto(qs):
    """
    O extrato do ERP contra a nossa apuração pelos XML: resumo, item a item,
    nota a nota, e o que o próprio extrato denuncia sozinho.
    """
    aid = int((qs.get("id") or ["0"])[0] or 0)
    if not aid:
        ultimo = query("select id from erp_extrato_arquivo "
                       "where vigente order by dt_ini desc, id desc limit 1")
        if not ultimo:
            return {"arquivo": None, "resumo": None, "itens": [],
                    "documentos": [], "alertas": []}
        aid = int(ultimo[0]["id"])
    arq = query("select id, nome_arquivo, deposito, cnpj, uf, dt_ini::text dt_ini, "
                "dt_fin::text dt_fin, linhas, itens, movimentos, aberturas, vigente, "
                "problemas from erp_extrato_arquivo where id = %d" % aid)
    if not arq:
        return {"erro": "extrato não encontrado"}
    resumo = query(f"select * from erp_confronto_resumo({aid})")
    return {
        "arquivo": arq[0],
        "resumo": resumo[0] if resumo else None,
        "itens": query(f"select * from erp_confronto_item({aid})"),
        "documentos": query(f"select *, dt::text dt_txt from erp_confronto_documento({aid})"),
        "alertas": query(f"select *, dt::text dt_txt from erp_extrato_alertas({aid})"),
    }


def sql_conferencia_cfop(mes, uf):
    ini, fim = _mes(mes, "2023-01")
    return f"select * from conferencia_cfop({ini}, {fim}, {_cnpj_da_uf(uf)})"


def sql_conferencia_cfop_detalhe(mes, uf, cfop, lado, funcao):
    """Itens ou notas de um CFOP. O lado vazio traz os dois."""
    ini, fim = _mes(mes, "2023-01")
    c = re.sub(r"\D", "", cfop)[:4]
    l = f"'{lado}'" if lado in ("emitente", "destino") else "null"
    return (f"select * from {funcao}({ini}, {fim}, '{c}', {_cnpj_da_uf(uf)}, {l})"
            if c else "select 1 where false")


def sql_periodo_resumo(mes, origem="nfe"):
    ini, fim = _mes(mes, "2023-01")
    org = origem if origem in ("nfe", "") else "nfe"
    return f"select * from estoque_periodo_resumo({ini}, {fim}, '{org}')"


def sql_inventario(uf, termo, limit, offset, ordem):
    w = ["1=1"]
    if uf in ("SP", "CE", "SC"):
        w.append(f"uf = '{uf}'")
    if termo:
        t = termo.replace("'", "''").upper()
        w.append(f"(upper(descr_item) like '%{t}%' or upper(cod_item) like '%{t}%' "
                 f"or coalesce(ncm,'') like '%{t}%')")
    cols = {"valor": "vl_item desc", "qtd": "qtd desc",
            "custo": "vl_unit desc", "codigo": "cod_item"}
    return (f"select uf, cnpj, cod_item, descr_item, ncm, unid, qtd, vl_unit, vl_item, "
            f"ind_prop, ind_prop_desc, depositario, "
            f"count(*) over() as total_geral "
            f"from v_inventario where {' and '.join(w)} "
            f"order by {cols.get(ordem, 'vl_item desc')} limit {int(limit)} offset {int(offset)}")


SQL_IMPORT_STATUS = """
select
  (select count(*) from nfe)                                   as notas,
  (select count(*) from nfe where situacao <> 'autorizada')     as nao_autorizadas,
  (select count(*) from nfe_item)                               as itens_nota,
  (select count(*) from movimento where origem = 'nfe')         as movimentos,
  (select count(*) from item_pendente where status = 'aberto')  as pendentes,
  (select count(*) from v_cfop_nao_classificado)                as cfops_abertos,
  (select min(dt_emi)::text from nfe)                           as primeira,
  (select max(dt_emi)::text from nfe)                           as ultima,
  (select coalesce(sum(vl_item),0) from saldo_abertura)         as abertura
"""

SQL_PENDENTES = """
select cnpj, parceiro_doc, parceiro_nome, c_prod_externo, x_prod, ncm, u_com,
       ocorrencias, qtd_total, vl_total, primeira_chave
from item_pendente where status = 'aberto'
order by vl_total desc nulls last limit 200
"""

SQL_NOTAS = """
select n.chave, n.num_nf, n.serie, n.dt_emi, n.nat_op, n.emit_cnpj, n.emit_nome,
       n.dest_doc, n.dest_nome, n.vl_nf, n.situacao, n.nome_arquivo,
       (select count(*) from nfe_item i where i.nfe_id = n.id)  as itens,
       (select count(*) from movimento m where m.nfe_id = n.id) as movs
from nfe n order by n.dt_emi desc nulls last, n.id desc limit 200
"""


def _sobe_auditoria():
    raiz = os.path.dirname(HERE)
    if raiz not in sys.path:
        sys.path.insert(0, raiz)


def importar_pasta(body):
    _sobe_auditoria()
    from auditoria import carga_nfe
    pasta = (body or {}).get("pasta") or os.path.join(os.path.dirname(HERE), "xmls")
    if not os.path.isdir(pasta):
        return {"erro": f"pasta não encontrada: {pasta}"}
    res = carga_nfe.importa_pasta(pasta)
    _cache.clear()
    return {"pasta": pasta, "resumo": carga_nfe.resumo(res),
            "arquivos": [r.dict() for r in res]}


def importar_upload(body):
    """Recebe os XMLs enviados pelo navegador, grava em disco e importa."""
    _sobe_auditoria()
    from auditoria import carga_nfe
    destino = os.path.join(os.path.dirname(HERE), "xmls", "recebidos")
    os.makedirs(destino, exist_ok=True)
    import base64
    from auditoria import carga, carga_ecd, carga_erp, ecd, erp, saldo_erp
    gravados, fatias = [], {}
    for arq in (body or {}).get("arquivos", []):
        nome = os.path.basename(arq.get("nome") or "")
        if not nome.lower().endswith((".xml", ".txt", ".xlsx", ".xlsm", ".json")):
            continue
        caminho = os.path.join(destino, nome)
        if "base64" in arq:
            # .txt chega em bytes: EFD e ECD são latin-1, e só assim o arquivo
            # gravado é idêntico ao original — com o mesmo hash.
            with open(caminho, "wb") as fh:
                fh.write(base64.b64decode(arq["base64"]))
        else:
            with open(caminho, "w", encoding="utf-8", newline="") as fh:
                fh.write(arq.get("conteudo") or "")
        gravados.append(caminho)
        if arq.get("extrato"):
            fatias[caminho] = arq["extrato"]
    if not gravados:
        return {"erro": "nenhum arquivo .xml, .txt, .xlsx ou .json recebido"}
    res = []
    for c in gravados:
        if c.lower().endswith(".xml"):
            res.append(carga_nfe.importa(c))
            continue
        if c.lower().endswith(".json"):
            # JSON do ERP: o extrato de movimentos ou o saldo de produtos,
            # reconhecidos pelas colunas — o nome do arquivo não decide nada.
            try:
                if c in fatias:
                    # Fatia de um extrato grande, cortada pelo navegador.
                    m = fatias[c]
                    r, bruto = carga_erp.importa_parte(c, m)
                    fim = bruto.get("situacao") != "parte"
                    av = ([f"Extrato do ERP: {r.linhas} linhas, depósito "
                           f"{r.deposito or '?'}"] if fim else
                          [f"parte {m.get('parte')} de {m.get('partes')} recebida"]) + \
                         [f"{t}: {d}" for t, d in r.problemas[:20]]
                    res.append(carga_nfe.ResultadoNFe(os.path.basename(c), r.situacao,
                                                      avisos=av))
                    continue
                if erp.e_extrato_erp(c):
                    r = carga_erp.importa(c)
                    av = [f"Extrato do ERP: {r.linhas} linhas, {r.itens} itens, "
                          f"depósito {r.deposito or '?'}"] + \
                         [f"{t}: {d}" for t, d in r.problemas[:20]]
                    res.append(carga_nfe.ResultadoNFe(os.path.basename(c), r.situacao,
                                                      avisos=av))
                    continue
                if not saldo_erp.e_saldo_erp(c):
                    raise ValueError("JSON não reconhecido — esperava o extrato "
                                     "de movimentos ou o saldo de produtos do ERP")
                r = carga_erp.importa_saldo(c)
                av = [f"Saldo do ERP em {r.dt}: {r.itens} itens, "
                      f"depósito {r.deposito or '?'}"] +                      [f"{t}: {d}" for t, d in r.problemas]
                res.append(carga_nfe.ResultadoNFe(os.path.basename(c), r.situacao, avisos=av))
            except Exception as e:
                res.append(carga_nfe.ResultadoNFe(os.path.basename(c), "ignorado",
                                                  avisos=[f"{type(e).__name__}: {e}"]))
            continue
        if c.lower().endswith((".xlsx", ".xlsm")):
            # Planilha: hoje só o extrato de produtos do ERP, reconhecido pelo
            # cabeçalho. Outra planilha é recusada com o motivo, e não em
            # silêncio — quem enviou precisa saber que não foi lida.
            try:
                if not erp.e_extrato_erp(c):
                    raise ValueError("planilha não reconhecida — esperava o "
                                     "extrato de produtos por depósito do ERP")
                r = carga_erp.importa(c)
                av = [f"ERP: {r.linhas} linhas, {r.itens} itens, "
                      f"depósito {r.deposito or '?'}"] + \
                     [f"{t}: {d}" for t, d in r.problemas]
                res.append(carga_nfe.ResultadoNFe(os.path.basename(c), r.situacao, avisos=av))
            except Exception as e:
                res.append(carga_nfe.ResultadoNFe(os.path.basename(c), "ignorado",
                                                  avisos=[f"{type(e).__name__}: {e}"]))
            continue
        # .txt: ECD ou EFD, pelo conteúdo.
        try:
            if ecd.e_ecd(c):
                r = carga_ecd.importa(c)
                av = [f"ECD: {r.contas} contas, {r.saldos} saldos"] + \
                     [f"{t}: {d}" for t, d in r.problemas]
            else:
                r = carga.importa(c)
                av = [f"EFD {k} {v}" for k, v in (r.contagens or {}).items()][:1] + \
                     [f"{t}: {d}" for t, d in r.problemas]
            res.append(carga_nfe.ResultadoNFe(os.path.basename(c), r.situacao, avisos=av))
        except Exception as e:
            res.append(carga_nfe.ResultadoNFe(os.path.basename(c), "ignorado",
                                              avisos=[f"{type(e).__name__}: {e}"]))
    _cache.clear()
    return {"destino": destino, "resumo": carga_nfe.resumo(res),
            "arquivos": [r.dict() for r in res]}


def _auth():
    _sobe_auditoria()
    from auditoria import auth
    return auth


def entrar(body):
    a = _auth()
    try:
        token, _refresh, u = a.entrar((body or {}).get("email", "").strip(),
                                      (body or {}).get("senha", ""))
    except a.ErroAuth as e:
        return {"erro": str(e)}, None
    return {"ok": True, "usuario": {"email": u.get("email")}}, token


def sair(body, token=None):
    _auth().sair(token)
    return {"ok": True}, ""


def mudar_status(body):
    import getpass
    quem = os.environ.get("AUDITOR") or getpass.getuser()
    aid = int((body or {}).get("id") or 0)
    st = str((body or {}).get("status") or "")
    nota = (body or {}).get("nota") or None
    r = query("select * from achado_mudar_status(" + str(aid) + ", '"
              + st.replace("'", "") + "', '" + quem.replace("'", "") + "', "
              + ("'" + nota.replace("'", "''") + "'" if nota else "null") + ")")
    _cache.clear()
    return r[0] if r else {"erro": "achado nao encontrado"}


def rodar_varredura(body):
    data = str((body or {}).get("data") or "2022-12-31").replace("'", "")
    import getpass
    quem = os.environ.get("AUDITOR") or getpass.getuser()
    r = query("select * from varrer(date '" + data + "', '" + quem.replace("'", "") + "')")
    _cache.clear()
    return r[0] if r else {}


def _texto(body, campo, tam=120):
    v = (body or {}).get(campo)
    v = ("" if v is None else str(v)).strip()[:tam]
    return "'" + v.replace("'", "''") + "'" if v else "null"


def trabalho_usar(body):
    """
    Troca o trabalho em uso. Limpa o cache: ele guarda o resultado por SQL, e o
    mesmo SQL passa a devolver outra coisa — sem isso o painel continuaria
    mostrando os números do trabalho anterior.
    """
    tid = int((body or {}).get("id") or 0)
    r = query(f"select * from trabalho_usar({tid}, {_texto(body, 'quem')})")
    _cache.clear()
    return r[0] if isinstance(r, list) and r else r


def trabalho_novo(body):
    nome = str((body or {}).get("nome") or "").strip()
    if not nome:
        return {"erro": "Dê um nome ao trabalho."}
    r = query("select * from trabalho_novo(" + _texto(body, "nome")
              + ", " + _texto(body, "cliente")
              + ", " + _texto(body, "exercicio")
              + ", " + _texto(body, "descricao", 600)
              + ", " + _texto(body, "quem") + ", true)")
    _cache.clear()
    return r[0] if isinstance(r, list) and r else r


def trabalho_excluir(body):
    """
    Apaga um trabalho e, por cascata, os dados dele. Duas travas: o nome tem de
    ser digitado igual, e o último trabalho não pode ser excluído — o sistema
    ficaria sem trabalho ativo e todas as telas em branco.
    """
    tid = int((body or {}).get("id") or 0)
    confirma = str((body or {}).get("confirma") or "")
    ts = query("select id, nome, ativo from v_trabalho order by id")
    alvo = next((t for t in ts if t["id"] == tid), None)
    if alvo is None:
        return {"erro": "Trabalho não encontrado."}
    if len(ts) == 1:
        return {"erro": "Este é o único trabalho. Crie outro antes de excluir este."}
    if confirma.strip() != alvo["nome"]:
        return {"erro": "O nome digitado não confere. Nada foi apagado."}
    query(f"delete from trabalho where id = {tid}")
    _cache.clear()
    if alvo["ativo"]:
        resto = [t for t in ts if t["id"] != tid][0]
        query(f"select trabalho_usar({resto['id']}, {_texto(body, 'quem')})")
        _cache.clear()
    return {"ok": True, "excluido": alvo["nome"]}


POSTS = {"/api/import/pasta": importar_pasta, "/api/import/upload": importar_upload,
         "/api/exportar": exportar,
         "/api/achados/status": mudar_status, "/api/varrer": rodar_varredura,
         "/api/trabalhos/usar": trabalho_usar, "/api/trabalhos/novo": trabalho_novo,
         "/api/trabalhos/excluir": trabalho_excluir}

# Rotas que dispensam sessão. Todo o resto exige login.
LIVRES = {"/login", "/login.html", "/app.css", "/app.js", "/favicon.ico",
          "/api/auth/login"}

ROUTES = {
    "/api/import/status": lambda qs: dict(query(SQL_IMPORT_STATUS)[0], importacao=True, pasta=True),
    "/api/import/pendentes": lambda qs: query(SQL_PENDENTES),
    "/api/import/cfop/detalhe": lambda qs: query(
        "select * from cfop_aberto_detalhe('"
        + (qs.get("cfop") or [""])[0].replace("'", "") + "')"),
    "/api/import/sugestoes": lambda qs: query(
        "select * from item_pendente_sugestoes('"
        + (qs.get("cnpj") or [""])[0].replace("'", "") + "','"
        + (qs.get("prod") or [""])[0].replace("'", "") + "')"),
    "/api/import/cfops": lambda qs: query("select * from v_cfop_nao_classificado limit 100"),
    "/api/import/notas": lambda qs: query(SQL_NOTAS),
    "/api/kpis": lambda qs: query(SQL_KPIS)[0],
    "/api/filiais": lambda qs: query(SQL_FILIAIS),
    "/api/divergencias": lambda qs: query(SQL_DIVERG),
    "/api/divergencias/detalhe": lambda qs: query(
        "select * from v_divergencia_detalhe order by exposicao desc"),
    "/api/divergencias/documentos": lambda qs: query(
        "select * from divergencia_documentos('"
        + (qs.get("cnpj") or [""])[0].replace("'", "") + "','"
        + (qs.get("item") or [""])[0].replace("'", "") + "')"),
    "/api/terceiros": lambda qs: query(SQL_TERCEIROS),
    "/api/top": lambda qs: query(SQL_TOP),
    "/api/achados": lambda qs: query(
        "select * from v_achado_painel where "
        + ("1=1" if (qs.get("todos") or [""])[0] == "1"
           else "status <> 'resolvido'")
        + (" and severidade = '" + (qs.get("sev") or [""])[0].replace("'", "") + "'"
           if (qs.get("sev") or [""])[0] in ("critico","alto","medio","informativo") else "")
        + (" and status = '" + (qs.get("status") or [""])[0].replace("'", "") + "'"
           if (qs.get("status") or [""])[0] in
              ("aberto","em_analise","respondido","aceito","refutado","resolvido") else "")
        + " order by ordem_status, ordem_sev, valor desc nulls last limit 400"),
    "/api/achados/resumo": lambda qs: query("select * from v_achado_resumo")[0],
    "/api/achados/eventos": lambda qs: query(
        "select * from achado_evento where achado_id = "
        + str(int((qs.get("id") or ["0"])[0])) + " order by quando"),
    "/api/materialidade": lambda qs: query("select * from materialidade_vigente()")[0],
    "/api/varreduras": lambda qs: query(
        "select * from varredura order by executada_em desc limit 20"),
    "/api/relatorio": lambda qs: query(
        "select * from relatorio_achados(date '"
        + (qs.get("data") or ["2022-12-31"])[0].replace("'", "") + "')"),
    "/api/relatorio/resumo": lambda qs: query(
        "select * from relatorio_resumo(date '"
        + (qs.get("data") or ["2022-12-31"])[0].replace("'", "") + "')")[0],
    "/api/relatorio/fontes": lambda qs: query("select * from v_relatorio_fontes"),
    "/api/kardex": lambda qs: query(sql_kardex(
        (qs.get("cnpj") or [""])[0],
        (qs.get("item") or [""])[0],
        (qs.get("ate") or [""])[0])),
    "/api/estoque": lambda qs: query(sql_estoque(
        (qs.get("data") or ["2022-12-31"])[0],
        (qs.get("uf") or [""])[0],
        (qs.get("q") or [""])[0],
        min(int((qs.get("limit") or ["60"])[0]), 500),
        int((qs.get("offset") or ["0"])[0]),
        (qs.get("ordem") or ["valor"])[0],
        (qs.get("situacao") or [""])[0])),
    "/api/estoque/resumo": lambda qs: query(
        "select * from estoque_resumo(date '"
        + (qs.get("data") or ["2022-12-31"])[0].replace("'", "") + "')")[0],
    "/api/datas": lambda qs: query(
        "select dt::text, movimentos, filiais from v_datas_movimento order by dt desc"),
    "/api/periodo": lambda qs: query(sql_periodo(
        (qs.get("mes") or [""])[0],
        (qs.get("uf") or [""])[0],
        (qs.get("q") or [""])[0],
        min(int((qs.get("limit") or ["60"])[0]), 500),
        int((qs.get("offset") or ["0"])[0]),
        (qs.get("ordem") or ["valor"])[0],
        (qs.get("situacao") or [""])[0],
        (qs.get("origem") or ["nfe"])[0])),
    "/api/periodo/resumo": lambda qs: query(sql_periodo_resumo(
        (qs.get("mes") or [""])[0], (qs.get("origem") or ["nfe"])[0]))[0],
    "/api/estoque/de-terceiros": lambda qs: query(
        "select * from estoque_de_terceiros(date '%s')"
        % (lambda d: d if re.match(r"^\d{4}-\d{2}-\d{2}$", d) else "2026-12-31")(
            (qs.get("data") or [""])[0])),
    "/api/resultado": resultado,
    "/api/apuracao": apuracao,
    "/api/apuracao/consistencia": apuracao_consistencia,
    "/api/periodo/faturamento": lambda qs: query(sql_faturamento(
        (qs.get("mes") or [""])[0], (qs.get("uf") or [""])[0])),
    "/api/periodo/faturamento/notas": lambda qs: query(sql_faturamento(
        (qs.get("mes") or [""])[0], (qs.get("uf") or [""])[0], "faturamento_notas")),
    "/api/periodo/bloqueios": lambda qs: query(
        sql_periodo_bloqueios((qs.get("mes") or [""])[0])),
    "/api/erp": erp_arquivos,
    "/api/erp/confronto": erp_confronto,
    "/api/erp/saldos": erp_saldos,
    "/api/erp/saldo": erp_saldo,
    "/api/real": real_resumo,
    "/api/real/produtos": _real_lista("erp_real_produtos"),
    "/api/real/sem-estoque": _real_lista("erp_real_sem_estoque"),
    "/api/real/sem-remessa": _real_lista("erp_real_sem_remessa"),
    "/api/real/terceiros": _real_lista("erp_real_em_terceiros"),
    "/api/real/inconsistencias": _real_lista("erp_real_inconsistencias"),
    "/api/real/kardex": real_kardex,
    "/api/periodo/cfops": lambda qs: query(sql_conferencia_cfop(
        (qs.get("mes") or [""])[0], (qs.get("uf") or [""])[0])),
    "/api/periodo/cfop/itens": lambda qs: query(sql_conferencia_cfop_detalhe(
        (qs.get("mes") or [""])[0], (qs.get("uf") or [""])[0],
        (qs.get("cfop") or [""])[0], (qs.get("lado") or [""])[0],
        "conferencia_cfop_itens")),
    "/api/periodo/cfop/notas": lambda qs: query(sql_conferencia_cfop_detalhe(
        (qs.get("mes") or [""])[0], (qs.get("uf") or [""])[0],
        (qs.get("cfop") or [""])[0], (qs.get("lado") or [""])[0],
        "conferencia_cfop_notas")),
    "/api/periodo/meses": lambda qs: query(
        "select mes, primeiro_dia::text, ultimo_dia::text, movimentos, "
        "       movimentos_nfe, filiais, itens "
        "from v_meses_movimento order by mes desc"),
    "/api/trabalhos": lambda qs: query(
        "select id, nome, cliente, exercicio, status, ativo, arquivos, notas, "
        "       movimentos, achados_abertos, abertura, ufs, "
        "       to_char(criado_em,'DD/MM/YYYY') as criado "
        "from v_trabalho order by id"),
    "/api/inventario": lambda qs: query(sql_inventario(
        (qs.get("uf") or [""])[0],
        (qs.get("q") or [""])[0],
        min(int((qs.get("limit") or ["60"])[0]), 500),
        int((qs.get("offset") or ["0"])[0]),
        (qs.get("ordem") or ["valor"])[0])),
}

MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml"}


def vigia_arquivos(intervalo=1.0):
    """
    Reinicia o processo quando um .py do projeto muda.

    Sem isto, editar o servidor e esquecer de reiniciá-lo faz a interface nova
    conversar com a lógica antiga. O sintoma não parece um servidor velho:
    parece funcionalidade quebrada. Aconteceu com o filtro de saldo negativo,
    que devolvia a lista inteira porque o processo em memória não conhecia o
    parâmetro que a página passou a enviar.

    Antes de reiniciar, confere se o arquivo compila. Editor salvando pela
    metade, ou erro de sintaxe, derrubaria o servidor num ciclo de reinícios.
    """
    import threading

    raiz = os.path.dirname(HERE)
    alvos = [os.path.join(HERE, "server.py")]
    pasta = os.path.join(raiz, "auditoria")
    if os.path.isdir(pasta):
        alvos += [os.path.join(pasta, f)
                  for f in sorted(os.listdir(pasta)) if f.endswith(".py")]
    marca = {a: os.path.getmtime(a) for a in alvos if os.path.exists(a)}

    def laco():
        while True:
            time.sleep(intervalo)
            for alvo in list(marca):
                try:
                    agora = os.path.getmtime(alvo)
                except OSError:
                    continue
                if agora == marca[alvo]:
                    continue
                marca[alvo] = agora
                nome = os.path.basename(alvo)
                try:
                    # compile() nao escreve nada. py_compile com cfile=os.devnull
                    # falha no Windows: 'nul' nao e arquivo regular, a checagem
                    # errava sempre e a recarga nunca acontecia.
                    with open(alvo, "rb") as fh:
                        compile(fh.read(), alvo, "exec")
                except (SyntaxError, ValueError) as e:
                    sys.stderr.write(
                        "\n  " + nome + " nao compila — servidor mantido no ar\n"
                        "    " + type(e).__name__ + ": " + str(e)[:160] + "\n\n")
                    sys.stderr.flush()
                    continue
                sys.stderr.write("\n  " + nome + " mudou — reiniciando\n\n")
                sys.stderr.flush()
                os.execv(sys.executable, [sys.executable] + sys.argv)

    threading.Thread(target=laco, daemon=True).start()
    return len(marca)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        try:
            msg = fmt % args
        except Exception:
            msg = " ".join(str(a) for a in args)
        if "/api/" in msg or " 4" in msg or " 5" in msg:
            sys.stderr.write("  %s\n" % msg)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            n = int(self.headers.get("Content-Length") or 0)
            corpo = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception as e:
            return self._send(400, json.dumps({"erro": f"corpo inválido: {e}"}))

        if path == "/api/auth/login":
            try:
                dados, token = entrar(corpo)
            except Exception as e:
                return self._send(500, json.dumps({"erro": str(e)}))
            if token is None:
                return self._send(401, json.dumps(dados))
            sys.stderr.write(f"  login: {dados['usuario']['email']}\n")
            return self._send(200, json.dumps(dados), cookie=token)

        if path == "/api/auth/logout":
            dados, _ = sair(corpo, self._token())
            return self._send(200, json.dumps(dados), cookie="")

        if not self._usuario():
            return self._send(401, json.dumps({"erro": "sessão expirada"}))

        rota = POSTS.get(path)
        if not rota:
            return self._send(404, json.dumps({"erro": "rota inexistente"}))
        try:
            return self._send(200, json.dumps(rota(corpo), default=str))
        except Exception as e:
            import traceback
            traceback.print_exc()
            return self._send(500, json.dumps({"erro": f"{type(e).__name__}: {e}"}))

    COOKIE = "fs_sessao"

    def _send(self, code, body, ctype="application/json; charset=utf-8",
              cookie=None, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        if cookie is not None:
            if cookie:
                self.send_header(
                    "Set-Cookie",
                    f"{self.COOKIE}={cookie}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200")
            else:
                self.send_header(
                    "Set-Cookie",
                    f"{self.COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _token(self):
        from http.cookies import SimpleCookie
        bruto = self.headers.get("Cookie")
        if not bruto:
            return None
        try:
            c = SimpleCookie()
            c.load(bruto)
            m = c.get(self.COOKIE)
            return m.value if m else None
        except Exception:
            return None

    def _usuario(self):
        return _auth().usuario(self._token())

    def do_GET(self):
        u = urlparse(self.path)
        path, qs = u.path, parse_qs(u.query)

        if path not in LIVRES and not self._usuario():
            if path.startswith("/api/"):
                return self._send(401, json.dumps({"erro": "sessão expirada"}))
            from urllib.parse import quote
            return self._send(302, b"", "text/plain",
                              extra={"Location": f"/login?de={quote(path)}"})

        if path == "/api/auth/me":
            return self._send(200, json.dumps({"usuario": self._usuario()}))

        if path in ROUTES:
            try:
                return self._send(200, json.dumps(ROUTES[path](qs), default=str))
            except Exception as e:
                sys.stderr.write(f"  ERRO {path}: {e}\n")
                return self._send(500, json.dumps({"erro": str(e)}))

        if path == "/":
            path = "/index.html"
        if path == "/reconstrucao":
            path = "/reconstrucao.html"
        if path == "/mes":
            path = "/mes.html"
        if path == "/apuracao":
            path = "/apuracao.html"
        if path == "/resultado":
            path = "/resultado.html"
        if path == "/importar":
            path = "/importar.html"
        if path == "/erp":
            path = "/erp.html"
        if path == "/estoque-real":
            path = "/estoque_real.html"
        if path == "/relatorio":
            path = "/relatorio.html"
        if path == "/manual":
            path = "/manual.html"
        if path == "/achados":
            path = "/achados.html"
        if path == "/login":
            path = "/login.html"

        # O manual mora na raiz do projeto, nao em static: e o mesmo arquivo
        # que o repositorio publica, para as duas versoes nunca divergirem.
        if path in ("/MANUAL.md", "/README.md"):
            doc = os.path.join(os.path.dirname(HERE), path.lstrip("/"))
            if os.path.isfile(doc):
                with open(doc, "rb") as fh:
                    return self._send(200, fh.read(), "text/markdown; charset=utf-8")
            return self._send(404, "manual nao encontrado", "text/plain; charset=utf-8")

        alvo = os.path.normpath(os.path.join(STATIC, path.lstrip("/")))
        if not alvo.startswith(STATIC) or not os.path.isfile(alvo):
            return self._send(404, "404", "text/plain; charset=utf-8")
        ext = os.path.splitext(alvo)[1]
        with open(alvo, "rb") as fh:
            self._send(200, fh.read(), MIME.get(ext, "application/octet-stream"))


if __name__ == "__main__":
    try:
        k = query(SQL_KPIS)[0]
        print(f"Banco OK  -> {k['itens']} itens de inventario, R$ {float(k['valor']):,.2f}, "
              f"data base {k['data_base']}")
    except Exception as e:
        print(f"AVISO: nao consegui falar com o banco agora ({e}).")
        print("O servidor sobe assim mesmo; o painel mostra o erro na tela.")
    if os.environ.get("SEM_RELOAD"):
        print("  Recarga automatica: desligada (SEM_RELOAD)")
    else:
        print(f"  Recarga automatica: vigiando {vigia_arquivos()} arquivos .py")
    print(f"\n  Auditoria Fiscal de Estoque")
    print(f"  http://localhost:{PORT}\n")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
# toque para testar a recarga automatica
