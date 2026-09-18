/* utilitários compartilhados pelas telas */

async function api(url) {
  const r = await fetch(url);
  const j = await r.json();
  if (!r.ok || j.erro) throw new Error(j.erro || ('HTTP ' + r.status));
  return j;
}

async function apiPost(url, corpo) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(corpo || {})
  });
  const j = await r.json();
  if (!r.ok || j.erro) throw new Error(j.erro || ('HTTP ' + r.status));
  return j;
}

const nf0 = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 0 });
const nf2 = new Intl.NumberFormat('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function n(v) { return nf0.format(+v || 0); }
function money(v) { return 'R$ ' + nf2.format(+v || 0); }
function pct(a, b) { return (+b ? (+a / +b * 100) : 0).toFixed(1) + '%'; }

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"]/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function cnpj(v) {
  const s = String(v || '').replace(/\D/g, '').padStart(14, '0');
  return `${s.slice(0,2)}.${s.slice(2,5)}.${s.slice(5,8)}/${s.slice(8,12)}-${s.slice(12)}`;
}

function brDate(iso) {
  if (!iso) return '—';
  const [a, m, d] = String(iso).slice(0, 10).split('-');
  return `${d}/${m}/${a}`;
}

/** Preenche o tbody de uma tabela. `extra` injeta um <tfoot> opcional. */
function fill(id, rows, tpl, extra) {
  const t = document.getElementById(id);
  const tb = t.querySelector('tbody');
  if (!rows || !rows.length) {
    tb.innerHTML = `<tr><td colspan="99" class="skel">nenhum registro</td></tr>`;
    return;
  }
  tb.innerHTML = rows.map(r => '<tr>' + tpl(r) + '</tr>').join('');
  const old = t.querySelector('tfoot');
  if (old) old.remove();
  if (extra) t.insertAdjacentHTML('beforeend', extra);
}

function falha(e) {
  const el = document.getElementById('erro');
  if (el) {
    el.innerHTML = `<div class="err-box"><b>Não consegui ler o banco.</b><br>
      ${esc(e.message)}<br><br>
      O projeto Supabase pausa por inatividade no plano free. Se for isso, abra o painel
      do Supabase para religá-lo e recarregue esta página.</div>`;
  }
  document.querySelectorAll('.skel').forEach(s => s.textContent = '—');
}

/** Liga o botão Sair presente no cabeçalho das telas autenticadas. */
function ligarSair() {
  const b = document.getElementById('btn-sair');
  if (!b) return;
  b.addEventListener('click', async e => {
    e.preventDefault();
    await fetch('/api/auth/logout', { method: 'POST' });
    location.href = '/login';
  });
}

/* ------------------------------------------------- ficha do item (Kardex)
 * Vive aqui, e não na tela, porque duas telas abrem a mesma ficha: a posição
 * acumulada e a movimentação do mês. Duplicada, divergiria na primeira
 * correção que alguém fizesse só num lado.
 */
const NAT = {
  abertura: 'abertura', transferencia: 'transferência', posse: 'muda de posse',
  entrada: 'entrada', saida: 'saída', simbolico: 'simbólico',
  terceiro: 'bem de terceiro',
};

function cardF(lbl, val, cls) {
  return `<div class="card ${cls || ''}"><div class="lbl">${lbl}</div>
          <div class="val sm">${val}</div></div>`;
}

/**
 * Abre a ficha do item num painel, sem sair da tela.
 *
 * `ate` é a data limite do Kardex. `nota` é um aviso opcional no topo: quem
 * chega pela tela do mês precisa saber que o histórico aqui é o completo,
 * inclusive o que veio antes do mês — é justamente isso que explica um saldo
 * negativo lá.
 */
async function abrirFicha(item, ate, nota) {
  const { corpo } = abrirPainel(
    esc(item.descr_item || item.cod_item),
    `${chipUF(item.uf)} código <b class="mono">${esc(item.cod_item)}</b> · ` +
    `NCM <span class="mono">${esc(item.ncm || '—')}</span> · posição em ${brDate(ate)}`);
  let mov;
  try {
    mov = await api(`/api/kardex?cnpj=${encodeURIComponent(item.cnpj)}` +
                    `&item=${encodeURIComponent(item.cod_item)}&ate=${ate}`);
  } catch (e) {
    corpo.innerHTML = `<div class="err-box">Não consegui carregar a ficha.<br>${esc(e.message)}</div>`;
    return;
  }
  if (!mov.length) {
    corpo.innerHTML = '<div class="skel">Nenhum movimento até esta data.</div>';
    return;
  }

  const ult = mov[mov.length - 1];
  const totalEnt = mov.reduce((a, m) => a + (+m.entrada || 0), 0);
  const totalSai = mov.reduce((a, m) => a + (+m.saida || 0), 0);

  corpo.innerHTML = `
    ${nota ? `<div class="motivo">${nota}</div>` : ''}
    <section class="grid kpis" style="margin-bottom:16px">
      ${cardF('Saldo em ' + brDate(ate), n(ult.saldo_qtd), (+ult.saldo_qtd < 0 ? 'alert' : ''))}
      ${cardF('Custo médio', money(ult.custo_medio))}
      ${cardF('Valor', money(ult.saldo_valor), (+ult.saldo_valor < 0 ? 'alert' : ''))}
      ${cardF('Entradas', n(totalEnt))}
      ${cardF('Saídas', n(totalSai))}
      ${cardF('Em terceiros', n(ult.saldo_terceiros))}
    </section>
    <div class="wrap">
      <table>
        <thead><tr>
          <th>#</th><th>Data</th><th>Documento</th><th>Movimento</th>
          <th>CFOP</th><th class="desc">Contraparte</th>
          <th class="num">Entrada</th><th class="num">Saída</th>
          <th class="num">Vl. unit.</th><th class="num">Saldo</th>
          <th class="num">Custo médio</th><th class="num">Valor</th>
        </tr></thead>
        <tbody>${mov.map(m => `<tr>
          <td class="mono">${m.seq}</td>
          <td class="mono">${brDate(m.dt)}</td>
          <td class="mono">${m.num_nf ? esc(m.num_nf) + '/' + esc(m.serie || '') : '<span class="muted">abertura</span>'}</td>
          <td><span class="nat nat-${m.natureza_mov}" title="${
              esc(m.natureza || '')}">${NAT[m.natureza_mov] || m.natureza_mov}</span></td>
          <td class="mono" title="${esc(m.cfop_descr || '')}">${esc(m.cfop || '—')}</td>
          <td class="desc">${m.interna
              ? chipUF(m.contraparte_uf) + ' <span class="muted">' +
                esc((m.contraparte || '').slice(0, 26)) + '</span>'
              : esc((m.contraparte || '—').slice(0, 34))}</td>
          <td class="num ent">${m.entrada ? n(m.entrada) : ''}</td>
          <td class="num sai">${m.saida ? n(m.saida) : ''}</td>
          <td class="num">${m.vl_unit_mov ? money(m.vl_unit_mov) : '—'}</td>
          <td class="num"><b>${+m.saldo_qtd < 0
              ? `<span class="chip err">${n(m.saldo_qtd)}</span>` : n(m.saldo_qtd)}</b></td>
          <td class="num">${money(m.custo_medio)}</td>
          <td class="num">${money(m.saldo_valor)}</td>
        </tr>`).join('')}</tbody>
      </table>
    </div>
    <p class="muted" style="font-size:12.5px;margin-top:12px">
      O saldo e o custo médio são corridos: cada linha mostra a posição depois
      daquele movimento. Saídas baixam pelo custo médio vigente — a coluna
      Vl. unit. numa venda é o preço da nota, não o custo.
      <br><b>Transferência</b> é movimento entre filiais do próprio grupo, e a
      sigla mostra qual. <b>Muda de posse</b> não altera o patrimônio: a
      mercadoria sai do seu poder e continua sendo sua — é o caso da remessa
      para armazém geral e da remessa em locação. <b>Bem de terceiro</b> é o
      equipamento do cliente recebido para conserto e devolvido a ele: entra e
      sai da sua guarda sem nunca entrar no seu saldo.
    </p>`;
}


/* ------------------------------------------------------------ trabalhos
 * Cada auditoria é um trabalho, e o painel inteiro mostra um por vez. O
 * seletor fica no cabeçalho de todas as telas porque a pergunta "de qual
 * cliente é este número?" vale em todas elas.
 */

/** Desenha o seletor no cabeçalho. Silencioso se o banco ainda não tem a
 *  tabela: telas antigas continuam abrindo. */
async function ligarTrabalhos() {
  const alvo = document.querySelector('header.top .tabs');
  if (!alvo) return;
  let ts;
  try { ts = await api('/api/trabalhos'); } catch (e) { return; }
  if (!Array.isArray(ts) || !ts.length) return;

  const atual = ts.find(t => t.ativo) || ts[0];
  const cx = document.createElement('div');
  cx.className = 'trab';
  cx.innerHTML = `<button class="trab-botao" title="Trocar de auditoria">
      <span class="trab-rot">Trabalho</span>
      <span class="trab-nome">${esc(atual.nome)}</span>
      <span class="trab-seta">▾</span>
    </button>`;
  alvo.parentNode.insertBefore(cx, alvo.nextSibling);
  cx.querySelector('.trab-botao').onclick = () => painelTrabalhos(ts);
}

function painelTrabalhos(ts) {
  const p = abrirPainel('Trabalhos',
    'Cada trabalho é uma auditoria isolada. Os dados de um não aparecem no outro.');
  const linhas = ts.map(t => `
    <div class="trab-item${t.ativo ? ' on' : ''}">
      <div class="trab-item-topo">
        <strong>${esc(t.nome)}</strong>
        ${t.ativo ? '<span class="chip">em uso</span>' : ''}
      </div>
      <div class="meta">${[t.cliente, t.exercicio, t.ufs].filter(Boolean).map(esc).join(' · ') || '—'}</div>
      <div class="meta">${n(t.arquivos)} arquivos · ${n(t.notas)} notas ·
        ${n(t.movimentos)} movimentos · ${n(t.achados_abertos)} achados em aberto ·
        abertura ${money(t.abertura)}</div>
      <div class="trab-acoes">
        ${t.ativo ? '' : `<button data-usar="${t.id}">Usar este</button>`}
        <button class="perigo" data-excluir="${t.id}">Excluir</button>
      </div>
    </div>`).join('');

  p.corpo.innerHTML = `
    ${linhas}
    <div class="trab-novo">
      <h3>Nova auditoria</h3>
      <p class="meta">Começa vazia. Os arquivos que você importar depois ficam
        só nela — nada se mistura com o que já está no sistema.</p>
      <label>Nome <input id="tn-nome" maxlength="120" placeholder="Ex.: ACME — reconstrução 2023"></label>
      <label>Cliente <input id="tn-cliente" maxlength="120"></label>
      <label>Exercício <input id="tn-exercicio" maxlength="40" placeholder="2023"></label>
      <button id="tn-criar" class="pri">Criar e usar</button>
      <div id="tn-erro" class="erro-inline"></div>
    </div>`;

  const erro = m => { p.corpo.querySelector('#tn-erro').textContent = m; };

  p.corpo.querySelectorAll('[data-usar]').forEach(b => b.onclick = async () => {
    b.disabled = true;
    try { await apiPost('/api/trabalhos/usar', { id: +b.dataset.usar }); location.reload(); }
    catch (e) { b.disabled = false; erro(e.message); }
  });

  p.corpo.querySelectorAll('[data-excluir]').forEach(b => b.onclick = async () => {
    const t = ts.find(x => x.id === +b.dataset.excluir);
    // O nome digitado é a confirmação. Um "tem certeza?" não protege de
    // engano — aqui o passo obriga a olhar de qual trabalho se trata.
    const dito = prompt(
      `Isto apaga o trabalho e tudo que está nele: ${n(t.arquivos)} arquivos, ` +
      `${n(t.notas)} notas, ${n(t.movimentos)} movimentos e ${n(t.achados_abertos)} ` +
      `achados. Não há como desfazer.\n\n` +
      `Para confirmar, digite o nome do trabalho:\n${t.nome}`);
    if (dito === null) return;
    b.disabled = true;
    try { await apiPost('/api/trabalhos/excluir', { id: t.id, confirma: dito }); location.reload(); }
    catch (e) { b.disabled = false; erro(e.message); }
  });

  p.corpo.querySelector('#tn-criar').onclick = async ev => {
    const nome = p.corpo.querySelector('#tn-nome').value.trim();
    if (!nome) { erro('Dê um nome ao trabalho.'); return; }
    ev.target.disabled = true;
    try {
      await apiPost('/api/trabalhos/novo', {
        nome,
        cliente: p.corpo.querySelector('#tn-cliente').value.trim(),
        exercicio: p.corpo.querySelector('#tn-exercicio').value.trim()
      });
      location.href = '/importar';
    } catch (e) { ev.target.disabled = false; erro(e.message); }
  };
}

/** Cor de cada filial. Uma fonte só, para tabela, legenda e gráfico não
 *  divergirem quando alguém mexer numa delas. */
const CORES_UF = { SP: '#4a6bb5', CE: '#2a8f92', SC: '#b04a90' };

/** Chip da filial, já com a classe da cor. */
function chipUF(uf) {
  const u = (uf || '').toUpperCase();
  return `<span class="chip uf${CORES_UF[u] ? ' uf-' + u : ''}">${esc(uf || '—')}</span>`;
}


/** Painel lateral de detalhe. Devolve o elemento do corpo, para quem chamou
 *  preencher depois de buscar os dados. Fecha por Esc, clique fora ou botao. */
function abrirPainel(titulo, meta) {
  const fundo = document.createElement('div');
  fundo.className = 'painel-fundo';
  fundo.innerHTML = `<div class="painel" role="dialog" aria-modal="true">
      <div class="painel-topo">
        <div><h2>${titulo}</h2><div class="meta">${meta || ''}</div></div>
        <button class="painel-fechar">Fechar</button>
      </div>
      <div class="painel-corpo"><div class="skel">carregando…</div></div>
    </div>`;
  document.body.appendChild(fundo);
  const fechar = () => { fundo.remove(); document.removeEventListener('keydown', tecla); };
  const tecla = e => { if (e.key === 'Escape') fechar(); };
  document.addEventListener('keydown', tecla);
  fundo.onclick = e => { if (e.target === fundo) fechar(); };
  fundo.querySelector('.painel-fechar').onclick = fechar;
  fundo.querySelector('.painel-fechar').focus();
  return { corpo: fundo.querySelector('.painel-corpo'), fechar };
}
