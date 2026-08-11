/* utilitários compartilhados pelas telas */

async function api(url) {
  const r = await fetch(url);
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
