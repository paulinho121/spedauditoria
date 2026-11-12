# -*- coding: utf-8 -*-
"""
Exportação de uma tabela para .xlsx ou .pdf, com a biblioteca padrão.

O papel de trabalho sai do sistema e vai para o cliente, para o fisco ou para
o processo. Depender de biblioteca externa para isso significaria que a função
serverless — que hoje instala apenas o psycopg — não exportaria nada.

As duas saídas recebem a mesma coisa: um título, uma lista de colunas e as
linhas. A coluna diz o nome da chave, o rótulo que aparece e o tipo:

    {"campo": "valor", "rotulo": "Valor", "tipo": "dinheiro"}

Tipo decide alinhamento e formato — 'texto' (padrão), 'numero', 'dinheiro',
'data'. Número sai como número, e não como texto: planilha com número em
formato de texto não soma, e quem recebe o relatório vai querer somar.

Coluna com "soma": True ganha uma linha de total no fim. Na planilha o total é
uma fórmula sobre as linhas, e não um número colado: quem apagar ou corrigir
uma linha vê o total acompanhar.
"""
import datetime
import io
import re
import zipfile

NUM = {"numero", "dinheiro"}


# --------------------------------------------------------------------- xlsx

TIPOS_XLSX = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>"""

RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""

RELS_WB = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>"""

WORKBOOK_XLSX = """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="{aba}" sheetId="1" r:id="rId1"/></sheets></workbook>"""

# 0 texto · 1 cabeçalho (negrito) · 2 dinheiro · 3 número · 4 título
# 5 total em dinheiro · 6 total em número (negrito, com o fundo do cabeçalho)
ESTILOS = """<?xml version="1.0" encoding="UTF-8"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2">
  <numFmt numFmtId="164" formatCode="#,##0.00"/>
  <numFmt numFmtId="165" formatCode="#,##0.###"/>
</numFmts>
<fonts count="3">
  <font><sz val="11"/><name val="Calibri"/></font>
  <font><b/><sz val="11"/><name val="Calibri"/></font>
  <font><b/><sz val="13"/><name val="Calibri"/></font>
</fonts>
<fills count="3">
  <fill><patternFill patternType="none"/></fill>
  <fill><patternFill patternType="gray125"/></fill>
  <fill><patternFill patternType="solid"><fgColor rgb="FFE6E8EA"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="7">
  <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
  <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
  <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
  <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
  <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
  <xf numFmtId="164" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyNumberFormat="1"/>
  <xf numFmtId="165" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyNumberFormat="1"/>
</cellXfs>
</styleSheet>"""


def _col(i):
    """0 -> A, 26 -> AA."""
    s, i = "", i + 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def _xml(t):
    return (str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            # Caractere de controle quebra o arquivo inteiro no Excel.
            .translate({c: None for c in range(9)}))


def _numero(v):
    """Texto do banco vira número; o que não for número fica como texto."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    t = str(v or "").strip()
    if not t:
        return None
    try:
        return float(t)
    except ValueError:
        return None


def totais(colunas, linhas):
    """Soma de cada coluna marcada com "soma". Célula vazia não entra."""
    t = {}
    for c in colunas:
        if c.get("soma") and c.get("tipo") in NUM:
            t[c["campo"]] = round(sum(_numero(l.get(c["campo"])) or 0.0
                                      for l in linhas), 6)
    return t


def xlsx(titulo, colunas, linhas, aba="Relatório", subtitulo=""):
    """Planilha de uma aba: título, cabeçalho, as linhas e o total, se pedido."""
    corpo, n = [], 0

    def celula(ref, valor, estilo, numerica=False):
        if numerica:
            return f'<c r="{ref}" s="{estilo}"><v>{valor!r}</v></c>'
        return (f'<c r="{ref}" s="{estilo}" t="inlineStr">'
                f"<is><t xml:space=\"preserve\">{_xml(valor)}</t></is></c>")

    n += 1
    corpo.append(f'<row r="{n}">{celula("A%d" % n, titulo, 4)}</row>')
    n += 1
    corpo.append(f'<row r="{n}">{celula("A%d" % n, _carimbo(), 0)}</row>')
    n += 1  # separa o título da tabela; leva o subtítulo, quando há
    if subtitulo:
        corpo.append(f'<row r="{n}">{celula("A%d" % n, subtitulo, 0)}</row>')
    n += 1
    primeira = n + 1
    corpo.append(f'<row r="{n}">' + "".join(
        celula(f"{_col(i)}{n}", c.get("rotulo") or c["campo"], 1)
        for i, c in enumerate(colunas)) + "</row>")

    for linha in linhas:
        n += 1
        cs = []
        for i, c in enumerate(colunas):
            ref = f"{_col(i)}{n}"
            v = linha.get(c["campo"])
            if c.get("tipo") in NUM:
                num = _numero(v)
                cs.append(celula(ref, num, 2 if c.get("tipo") == "dinheiro" else 3, True)
                          if num is not None else celula(ref, "", 0))
            else:
                cs.append(celula(ref, formata(v, c.get("tipo")) if c.get("tipo") == "data"
                                 else ("" if v is None else v), 0))
        corpo.append(f'<row r="{n}">' + "".join(cs) + "</row>")

    soma = totais(colunas, linhas)
    if soma and linhas:
        ultima, n = n, n + 1
        cs = []
        for i, c in enumerate(colunas):
            ref = f"{_col(i)}{n}"
            if c["campo"] in soma:
                faixa = f"{_col(i)}{primeira}:{_col(i)}{ultima}"
                # Fórmula com o valor já calculado ao lado: abre certo também em
                # leitor que não recalcula.
                cs.append(f'<c r="{ref}" s="{5 if c.get("tipo") == "dinheiro" else 6}">'
                          f"<f>SUM({faixa})</f><v>{soma[c['campo']]!r}</v></c>")
            else:
                cs.append(celula(ref, "Total" if i == 0 else "", 1))
        corpo.append(f'<row r="{n}">' + "".join(cs) + "</row>")

    larguras = "".join(
        f'<col min="{i+1}" max="{i+1}" width="{_largura(c, linhas)}" customWidth="1"/>'
        for i, c in enumerate(colunas))
    sheet = ('<?xml version="1.0" encoding="UTF-8"?>'
             '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
             f"<cols>{larguras}</cols><sheetData>" + "".join(corpo) + "</sheetData></worksheet>")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", TIPOS_XLSX)
        z.writestr("_rels/.rels", RELS)
        z.writestr("xl/workbook.xml", WORKBOOK_XLSX.format(aba=_xml(aba)[:28]))
        z.writestr("xl/_rels/workbook.xml.rels", RELS_WB)
        z.writestr("xl/styles.xml", ESTILOS)
        z.writestr("xl/worksheets/sheet1.xml", sheet)
    return buf.getvalue()


def _largura(coluna, linhas):
    maior = len(str(coluna.get("rotulo") or coluna["campo"]))
    for l in linhas[:400]:          # amostra basta para dimensionar
        maior = max(maior, len(str(l.get(coluna["campo"]) or "")))
    return min(max(maior + 2, 9), 56)


def _carimbo():
    return ("Fiscal Stock · gerado em "
            + datetime.datetime.now().strftime("%d/%m/%Y às %H:%M"))


def formata(valor, tipo):
    """
    Como o número aparece para quem lê. Vale para o PDF e para a data na
    planilha — nas colunas numéricas do .xlsx o valor continua número, com
    formato de célula, porque relatório que chega em texto não soma.
    """
    if valor is None or valor == "":
        return ""
    if tipo == "data":
        t = str(valor)[:10]
        m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", t)
        return f"{m.group(3)}/{m.group(2)}/{m.group(1)}" if m else str(valor)
    if tipo in NUM:
        n = _numero(valor)
        if n is None:
            return str(valor)
        if tipo == "dinheiro":
            t = f"{n:,.2f}"
        else:
            t = f"{n:,.3f}".rstrip("0").rstrip(".")
            if not t or t in ("-", ""):
                t = "0"
        return t.replace(",", "@").replace(".", ",").replace("@", ".")
    return str(valor)


# ---------------------------------------------------------------------- pdf
#
# PDF escrito à mão. A fonte é a Helvetica embutida no leitor (Type1 base 14),
# com WinAnsiEncoding, que cobre o português. A largura de cada caractere sai
# da tabela de métricas abaixo — sem ela, o texto da coluna invadiria a
# seguinte, e um relatório ilegível não é relatório.

PAGINA = (842, 595)          # A4 deitado: tabela larga cabe melhor
MARGEM = 34
_TOTAL = "__total__"       # marca a linha de total; não colide com campo

# Métricas da Helvetica (milésimos do corpo) para o ASCII imprimível.
_W = {
    " ": 278, "!": 278, '"': 355, "#": 556, "$": 556, "%": 889, "&": 667, "'": 191,
    "(": 333, ")": 333, "*": 389, "+": 584, ",": 278, "-": 333, ".": 278, "/": 278,
    "0": 556, "1": 556, "2": 556, "3": 556, "4": 556, "5": 556, "6": 556, "7": 556,
    "8": 556, "9": 556, ":": 278, ";": 278, "<": 584, "=": 584, ">": 584, "?": 556,
    "@": 1015, "[": 278, "\\": 278, "]": 278, "^": 469, "_": 556, "`": 333,
    "{": 334, "|": 260, "}": 334, "~": 584,
}
for _c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
    _W[_c] = {"I": 278, "J": 500, "L": 556, "M": 833, "W": 944}.get(_c, 667)
for _c in "abcdefghijklmnopqrstuvwxyz":
    _W[_c] = {"f": 278, "i": 222, "j": 222, "l": 222, "m": 833, "r": 333,
              "t": 278, "w": 722}.get(_c, 556)


def _larg(texto, corpo):
    return sum(_W.get(c, 556) for c in texto) * corpo / 1000.0


def _corta(texto, corpo, limite):
    """Corta no que cabe, com reticências — melhor que invadir a coluna."""
    if _larg(texto, corpo) <= limite:
        return texto
    fim = ""
    while texto and _larg(texto + "…", corpo) > limite:
        texto = texto[:-1]
        fim = "…"
    return texto + fim


def _txt(s):
    """Texto para o stream: Latin-1, com os parênteses e a barra escapados."""
    s = str(s if s is not None else "")
    s = s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
    return s


def pdf(titulo, subtitulo, colunas, linhas):
    larg_util = PAGINA[0] - 2 * MARGEM
    pesos = []
    for c in colunas:
        amostra = [formata(l.get(c["campo"]), c.get("tipo")) for l in linhas[:300]]
        maior = max([len(str(c.get("rotulo") or c["campo"]))] +
                    [len(a) for a in amostra] or [8])
        pesos.append(min(maior, 42))
    total = sum(pesos) or 1
    larguras = [max(38, larg_util * p / total) for p in pesos]
    # Depois do mínimo de 38pt a soma pode estourar; reparte o excesso.
    sobra = sum(larguras) - larg_util
    if sobra > 0:
        folgados = [i for i, w in enumerate(larguras) if w > 60]
        for i in folgados:
            larguras[i] -= sobra / len(folgados)

    corpo, cab = 7.5, 8
    altura_linha = 12.5
    topo = PAGINA[1] - MARGEM - 34
    por_pagina = max(1, int((topo - MARGEM - 16) / altura_linha))

    # O total entra como última linha da tabela, em negrito. Vai na paginação
    # junto com as outras: nunca fica espremido no rodapé.
    soma = totais(colunas, linhas)
    corpo_tab = list(linhas)
    if soma and linhas:
        total_linha = dict(soma)
        if colunas[0]["campo"] not in soma:
            total_linha[colunas[0]["campo"]] = "Total"
        total_linha[_TOTAL] = True
        corpo_tab.append(total_linha)

    paginas, i = [], 0
    while True:
        paginas.append(corpo_tab[i:i + por_pagina])
        i += por_pagina
        if i >= len(corpo_tab):
            break
    if not corpo_tab:
        paginas = [[]]

    fluxos = []
    for np, pagina in enumerate(paginas, start=1):
        s = []
        # Título e subtítulo
        s.append("BT /F2 13 Tf 1 0 0 1 %.1f %.1f Tm (%s) Tj ET"
                 % (MARGEM, PAGINA[1] - MARGEM - 8, _txt(titulo)))
        s.append("BT /F1 8 Tf 1 0 0 1 %.1f %.1f Tm (%s) Tj ET"
                 % (MARGEM, PAGINA[1] - MARGEM - 21, _txt(subtitulo or _carimbo())))
        # Cabeçalho da tabela, repetido em toda página
        y = topo
        s.append("0.90 0.91 0.92 rg %.1f %.1f %.1f %.1f re f"
                 % (MARGEM, y - 3, larg_util, altura_linha))
        s.append("0 g")
        x = MARGEM
        for c, w in zip(colunas, larguras):
            rot = _corta(str(c.get("rotulo") or c["campo"]), cab, w - 6)
            px = x + w - 3 - _larg(rot, cab) if c.get("tipo") in NUM else x + 3
            s.append("BT /F2 %.1f Tf 1 0 0 1 %.1f %.1f Tm (%s) Tj ET"
                     % (cab, px, y, _txt(rot)))
            x += w
        y -= altura_linha

        for linha in pagina:
            e_total = bool(linha.get(_TOTAL))
            if e_total:
                s.append("0.90 0.91 0.92 rg %.1f %.1f %.1f %.1f re f"
                         % (MARGEM, y - 3, larg_util, altura_linha))
                s.append("0 g")
            x = MARGEM
            for c, w in zip(colunas, larguras):
                # No total só aparecem as colunas somadas e o rótulo; e o
                # rótulo é texto mesmo quando a primeira coluna é numérica.
                bruto = linha.get(c["campo"])
                v = (str(bruto) if e_total and isinstance(bruto, str)
                     else formata(bruto, c.get("tipo")))
                v = _corta(v, corpo, w - 6)
                px = x + w - 3 - _larg(v, corpo) if c.get("tipo") in NUM else x + 3
                s.append("BT /%s %.1f Tf 1 0 0 1 %.1f %.1f Tm (%s) Tj ET"
                         % ("F2" if e_total else "F1", corpo, px, y, _txt(v)))
                x += w
            y -= altura_linha

        s.append("BT /F1 7 Tf 1 0 0 1 %.1f %.1f Tm (%s) Tj ET"
                 % (MARGEM, MARGEM - 8,
                    _txt("%d linha(s) · página %d de %d" % (len(linhas), np, len(paginas)))))
        fluxos.append("\n".join(s).encode("cp1252", "replace"))

    return _monta_pdf(fluxos)


def _monta_pdf(fluxos):
    """Junta os objetos e escreve a tabela xref. Sem ela o arquivo não abre."""
    objetos = []            # 1-based; cada item é bytes do corpo do objeto
    n_fontes = 2
    primeiro_pagina = 3 + n_fontes          # 1 catálogo, 2 pages, 3..4 fontes

    objetos.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    ids_paginas = [primeiro_pagina + 2 * i for i in range(len(fluxos))]
    kids = " ".join(f"{i} 0 R" for i in ids_paginas)
    objetos.append(("<< /Type /Pages /Count %d /Kids [%s] >>"
                    % (len(fluxos), kids)).encode())
    objetos.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
                   b"/Encoding /WinAnsiEncoding >>")
    objetos.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold "
                   b"/Encoding /WinAnsiEncoding >>")
    for i, fluxo in enumerate(fluxos):
        conteudo_id = ids_paginas[i] + 1
        objetos.append((
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents %d 0 R >>"
            % (PAGINA[0], PAGINA[1], conteudo_id)).encode())
        objetos.append(b"<< /Length " + str(len(fluxo)).encode() + b" >>\nstream\n"
                       + fluxo + b"\nendstream")

    saida = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, corpo in enumerate(objetos, start=1):
        offsets.append(len(saida))
        saida += b"%d 0 obj\n" % i + corpo + b"\nendobj\n"
    inicio_xref = len(saida)
    saida += b"xref\n0 %d\n" % (len(objetos) + 1)
    saida += b"0000000000 65535 f \n"
    for off in offsets:
        saida += b"%010d 00000 n \n" % off
    saida += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
              % (len(objetos) + 1, inicio_xref))
    return bytes(saida)


def nome_arquivo(titulo, formato):
    """Nome previsível, sem acento e sem espaço: ele vai virar anexo."""
    import unicodedata
    t = unicodedata.normalize("NFKD", titulo or "relatorio")
    t = "".join(c for c in t if not unicodedata.combining(c))
    t = re.sub(r"[^A-Za-z0-9]+", "_", t).strip("_").lower()[:60] or "relatorio"
    return f"{t}_{datetime.date.today():%Y%m%d}.{formato}"
