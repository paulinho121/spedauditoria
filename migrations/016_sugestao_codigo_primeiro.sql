-- 016 — Candidato com o mesmo codigo vem primeiro.
--
-- Ordenar so por similaridade de texto colocava o item errado no topo: para o
-- pendente 4035 ("LS 1200D PRO - LUMINARIA DE LED, FOTOMETRIA DE 83.100LUX"),
-- o candidato 4089 aparecia acima do proprio 4035, porque a descricao do
-- cadastro e mais curta e o trigrama penaliza diferenca de tamanho.
--
-- Codigo identico e sinal forte: nas transferencias entre filiais o cProd e o
-- codigo do grupo. Nao basta sozinho (o codigo 4061 e refletor em SP e pinca
-- em SC), mas combinado com semelhanca de descricao resolve com seguranca.

-- A assinatura ganhou a coluna confianca: create or replace nao muda tipo de
-- retorno, entao a funcao precisa cair antes.
drop function if exists item_pendente_sugestoes(text, text);

create function item_pendente_sugestoes(p_cnpj text, p_c_prod text)
returns table (
  cod_item      text,
  descr_item    text,
  ncm           text,
  unid_inv      text,
  semelhanca    real,
  ja_no_estoque boolean,
  origem        text,
  confianca     text
)
language sql stable as $$
  with alvo as (
    select x_prod, ncm from item_pendente
    where cnpj = p_cnpj and c_prod_externo = p_c_prod limit 1
  ),
  cand as (
    select si.cod_item, si.descr_item, si.ncm, si.unid_inv,
           similarity(upper(si.descr_item), upper((select x_prod from alvo))) as sim,
           si.cod_item = p_c_prod                            as mesmo_codigo,
           si.ncm = (select ncm from alvo)                   as mesmo_ncm
    from sped_item si
    join sped_arquivo a on a.id = si.arquivo_id and a.vigente
    where si.cnpj_estab = p_cnpj
      and (select x_prod from alvo) is not null
  )
  select c.cod_item, c.descr_item, c.ncm, c.unid_inv, c.sim,
         exists (select 1 from saldo_abertura sa
                 where sa.cnpj = p_cnpj and sa.cod_item = c.cod_item),
         concat_ws(' + ',
           case when c.mesmo_codigo then 'mesmo codigo' end,
           case when c.mesmo_ncm then 'mesmo NCM' end,
           case when c.sim >= 0.5 then 'descricao' end),
         case
           when c.mesmo_codigo and c.sim >= 0.5 then 'alta'
           when c.mesmo_codigo and c.mesmo_ncm  then 'alta'
           when c.mesmo_codigo                  then 'media'
           when c.sim >= 0.9                    then 'media'
           else 'baixa'
         end
  from cand c
  where c.mesmo_codigo or c.sim > 0.15
  -- codigo identico primeiro; depois NCM igual; so entao a semelhanca do texto
  order by c.mesmo_codigo desc, c.mesmo_ncm desc, c.sim desc
  limit 8;
$$;

comment on function item_pendente_sugestoes(text, text) is
  'Candidatos para resolver um item pendente. Ordena por codigo identico, NCM '
  'igual e semelhanca de descricao, nessa ordem. A coluna confianca resume.';
