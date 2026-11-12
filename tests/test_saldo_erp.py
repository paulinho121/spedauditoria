# -*- coding: utf-8 -*-
"""
Leitor do relatório "Saldo de produtos" do ERP.

O arquivo real é uma lista de objetos com nomes de coluna gerados pela tela
("columnprodutoCodigo2"), onde o número é só a ordem. O que decide a leitura:

  · o nome da coluna sem prefixo e sem sufixo — reordenar não pode quebrar;
  · a vírgula decimal e o ponto de milhar — 1.675 é mil seiscentos e setenta e
    cinco, não um e seiscentos e setenta e cinco milésimos;
  · o mesmo código em mais de uma linha, que o ERP exporta quando o produto
    tem mais de um cadastro — soma, com aviso.
"""
import json

import pytest

from auditoria import saldo_erp as se

REGISTROS = [
    {"columnlocalEscrituracao0": "LE MCI SC", "columndeposito1": "DEP MCI SC",
     "columnprodutoCodigo2": "3311",
     "columnprodutoNome3": "Sc302a Carregador Sequencial de 2 Canais",
     "columnprodutoUn4": "Un", "columnprodutoNcm5": "8504.40.10",
     "columnprodutoFabricante6": None, "columnsaldo7": "1"},
    {"columnlocalEscrituracao0": "LE MCI SC", "columndeposito1": "DEP MCI SC",
     "columnprodutoCodigo2": "3901", "columnprodutoNome3": "AL-MW Mini LED Light",
     "columnprodutoUn4": "Un", "columnprodutoNcm5": "9405.42.00",
     "columnprodutoFabricante6": None, "columnsaldo7": "4"},
    {"columnlocalEscrituracao0": "LE MCI SC", "columndeposito1": "DEP MCI SC",
     "columnprodutoCodigo2": "3901",
     "columnprodutoNome3": "AL-MW Mini LED Light — luz de vídeo compacta 5600K",
     "columnprodutoUn4": "Un", "columnprodutoNcm5": "9405.42.00",
     "columnprodutoFabricante6": None, "columnsaldo7": "25"},
    {"columnlocalEscrituracao0": "LE MCI SC", "columndeposito1": "DEP MCI SC",
     "columnprodutoCodigo2": "4512", "columnprodutoNome3": "Light Dome III",
     "columnprodutoUn4": "KG", "columnprodutoNcm5": "9405.99.00",
     "columnprodutoFabricante6": "Aputure", "columnsaldo7": "70,76"},
]


def arquivo(tmp_path, registros=None, nome="Saldo de produtos (20261112_131054).json"):
    caminho = tmp_path / nome
    caminho.write_text(json.dumps(registros if registros is not None else REGISTROS,
                                  ensure_ascii=False), encoding="utf-8")
    return str(caminho)


def test_reconhece_pelo_conteudo(tmp_path):
    assert se.e_saldo_erp(arquivo(tmp_path))
    outro = arquivo(tmp_path, [{"chave": "x", "valor": 1}], nome="outro.json")
    assert not se.e_saldo_erp(outro)
    assert not se.e_saldo_erp(arquivo(tmp_path, [], nome="vazio.json"))


def test_data_vem_do_nome_do_arquivo(tmp_path):
    assert se.parse(arquivo(tmp_path)).data == "2026-11-12"


def test_sem_data_no_nome_a_presuncao_fica_registrada(tmp_path):
    s = se.parse(arquivo(tmp_path, nome="saldo.json"))
    assert [t for t, _ in s.problemas if t == "data_presumida"]
    # E quem importa pode dizer a data, que é o caminho certo.
    assert se.parse(arquivo(tmp_path, nome="saldo.json"), data="2026-10-31").data \
        == "2026-10-31"


def test_le_codigo_descricao_unidade_e_ncm(tmp_path):
    s = se.parse(arquivo(tmp_path))
    l = s.linhas[0]
    assert l["cod_item"] == "3311"
    assert l["unid"] == "Un"
    assert l["ncm"] == "85044010"          # sem os pontos, oito dígitos
    assert l["deposito"] == "DEP MCI SC"
    assert l["local"] == "LE MCI SC"
    assert l["fabricante"] is None
    assert s.linhas[3]["fabricante"] == "Aputure"


def test_virgula_decimal_e_ponto_de_milhar():
    assert se.numero("70,76") == 70.76
    assert se.numero("1.675") == 1675          # milhar, não decimal
    assert se.numero("1.234,50") == 1234.5
    assert se.numero("12.5") == 12.5           # uma casa: decimal mesmo
    assert se.numero("-3") == -3
    assert se.numero("") is None and se.numero(None) is None
    assert se.numero("abc") is None


def test_codigo_repetido_e_somado_com_aviso(tmp_path):
    s = se.parse(arquivo(tmp_path))
    assert len(s.linhas) == 4 and s.itens == 3      # 3901 aparece duas vezes
    assert s.quantidade == pytest.approx(100.76)    # 1 + 4 + 25 + 70,76
    assert [d for t, d in s.problemas if t == "codigo_repetido"] == ["somados: 3901"]


def test_coluna_renomeada_ou_reordenada_continua_legivel(tmp_path):
    regs = [{"Saldo": "2", "Codigo": "99", "Nome": "Produto", "NCM": "94054200",
             "Deposito": "DEP MCI SC", "Unidade": "Un"}]
    s = se.parse(arquivo(tmp_path, regs))
    assert s.linhas[0]["cod_item"] == "99" and s.linhas[0]["qtd"] == 2
    assert s.linhas[0]["ncm"] == "94054200"


def test_lista_embrulhada_em_objeto(tmp_path):
    caminho = tmp_path / "Saldo (20261112_000000).json"
    caminho.write_text(json.dumps({"dados": REGISTROS}), encoding="utf-8")
    assert se.e_saldo_erp(str(caminho))
    assert se.parse(str(caminho)).itens == 3


def test_saldo_ilegivel_nao_derruba_o_arquivo(tmp_path):
    regs = REGISTROS + [{"columnprodutoCodigo2": "777", "columnsaldo7": "n/d",
                         "columndeposito1": "DEP MCI SC"}]
    s = se.parse(arquivo(tmp_path, regs))
    assert s.itens == 3                                   # o 777 ficou de fora
    assert [t for t, _ in s.problemas if t == "saldo_ilegivel"]


def test_json_sem_as_colunas_certas_e_recusado(tmp_path):
    caminho = tmp_path / "x.json"
    caminho.write_text(json.dumps([{"a": 1}]), encoding="utf-8")
    with pytest.raises(ValueError):
        se.parse(str(caminho))
