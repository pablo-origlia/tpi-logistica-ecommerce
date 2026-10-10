#!/usr/bin/env python3
"""
Análisis exhaustivo + contexto compacto en JSON del dataset
"DataCo SMART SUPPLY CHAIN FOR BIG DATA ANALYSIS" (Mendeley Data).

Fuente: https://data.mendeley.com/datasets/8gx2fvg2k6/5   (DOI 10.17632/8gx2fvg2k6.5)

Uso:
    python dataco_analysis.py --csv ./DataCoSupplyChainDataset.csv --output dataco_analysis.json

Opciones:
    --csv           archivo .csv o carpeta que lo contiene
    --description   (opcional) DescriptionDataCoSupplyChain.csv: se incorpora al contexto como descripción oficial
    --access-logs   (opcional) tokenized_access_logs.csv: perfil del clickstream y su solapamiento con el CSV principal
    --split-date    (opcional) corte temporal train/test del modelo base (por defecto: percentil 80 de fechas de pedido)
    --skip-ml       omite el modelo base (no requiere scikit-learn)
    --sample-rows   filas de ejemplo (sin datos personales) en el JSON completo

Genera:
    dataco_analysis.json           análisis completo
    dataco_analysis_context.json   contexto compacto para pegar en conversaciones futuras

Requisitos: pandas, numpy  (opcional: scikit-learn para el modelo base)

Criterios (quedan registrados en el JSON):
  - 1 fila = 1 ítem de pedido (se verifica); "pedido" = Order Id.
  - Los datos personales NUNCA se imprimen: solo se auditan (nulos, cardinalidad, si parecen enmascarados).
  - Lo "esperado" (dominios, descripciones) proviene de documentación de terceros y de nombres de columnas;
    lo "observado" sale de los datos. Se contrasta, no se asume.
  - El modelo base usa corte temporal y compara features "honestas" (conocidas al ordenar) con features que filtran el resultado.
"""
import argparse
import glob
import json
import math
import os
import platform
import re
import sys
import traceback
from datetime import datetime

import numpy as np
import pandas as pd

SCRIPT_VERSION = "1.3"
DATASET_URL = "https://data.mendeley.com/datasets/8gx2fvg2k6/5"
DOI = "10.17632/8gx2fvg2k6.5"
EDGE_FRAC = 0.001
MIN_MONTH_ITEMS = 500
K = {}  # KPIs para hallazgos automáticos


# ----------------------------------------------------------------------------
# Especificación de columnas (descripciones inferidas de los nombres; verificar con DescriptionDataCoSupplyChain.csv)
# kind: num | bin | cat | id | date | text | pii     role: feature | post_event | outcome | target | id | pii | text
# ----------------------------------------------------------------------------
def S(desc, kind, role="feature", note=None):
    return {"description": desc, "kind": kind, "role": role, "note": note}


SPEC = {
    "Type": S("Tipo de pago (esperado: DEBIT, TRANSFER, CASH, PAYMENT)", "cat"),
    "Days for shipping (real)": S("Días reales de envío", "num", "post_event", "solo se conoce después de despachar"),
    "Days for shipment (scheduled)": S("Días programados de envío", "num", "feature", "conocido al ordenar"),
    "Benefit per order": S("Beneficio (ganancia) por pedido", "num", "outcome"),
    "Sales per customer": S("Ventas por cliente (relación con Sales/Order Item Total a verificar)", "num"),
    "Delivery Status": S("Estado de entrega (Advance shipping, Late delivery, Shipping canceled, Shipping on time)",
                         "cat", "post_event", "resultado de la entrega: filtra la variable objetivo"),
    "Late_delivery_risk": S("Riesgo de entrega tardía (1 = tardía, 0 = no)", "bin", "target"),
    "Category Id": S("ID de categoría", "id", "id"),
    "Category Name": S("Nombre de categoría", "cat"),
    "Customer City": S("Ciudad del cliente", "cat"),
    "Customer Country": S("País del cliente", "cat"),
    "Customer Email": S("Email del cliente", "pii", "pii"),
    "Customer Fname": S("Nombre del cliente", "pii", "pii"),
    "Customer Id": S("ID del cliente", "id", "id"),
    "Customer Lname": S("Apellido del cliente", "pii", "pii"),
    "Customer Password": S("Contraseña del cliente", "pii", "pii"),
    "Customer Segment": S("Segmento del cliente (esperado: Consumer, Corporate, Home Office)", "cat"),
    "Customer State": S("Estado/provincia del cliente", "cat"),
    "Customer Street": S("Calle del cliente", "pii", "pii"),
    "Customer Zipcode": S("Código postal del cliente", "pii", "pii"),
    "Department Id": S("ID de departamento", "id", "id"),
    "Department Name": S("Nombre de departamento", "cat"),
    "Latitude": S("Latitud (semántica no documentada: cliente vs. tienda)", "num"),
    "Longitude": S("Longitud (semántica no documentada)", "num"),
    "Market": S("Mercado (esperado: LATAM, Europe, Pacific Asia, USCA, Africa)", "cat"),
    "Order City": S("Ciudad de destino del pedido", "cat"),
    "Order Country": S("País de destino del pedido", "cat"),
    "Order Customer Id": S("ID de cliente en el pedido (parece duplicar Customer Id)", "id", "id"),
    "order date (DateOrders)": S("Fecha y hora del pedido (texto M/D/AAAA H:MM)", "date"),
    "Order Id": S("ID del pedido (se repite por ítem)", "id", "id"),
    "Order Item Cardprod Id": S("ID de producto del ítem (parece duplicar Product Card Id)", "id", "id"),
    "Order Item Discount": S("Descuento del ítem (monto)", "num"),
    "Order Item Discount Rate": S("Tasa de descuento del ítem", "num"),
    "Order Item Id": S("ID del ítem de pedido (clave de fila)", "id", "id"),
    "Order Item Product Price": S("Precio unitario del producto en el ítem", "num"),
    "Order Item Profit Ratio": S("Razón de ganancia del ítem", "num", "outcome"),
    "Order Item Quantity": S("Cantidad del ítem", "num"),
    "Sales": S("Ventas del ítem (precio x cantidad, a verificar)", "num"),
    "Order Item Total": S("Total del ítem (ventas - descuento, a verificar)", "num"),
    "Order Profit Per Order": S("Ganancia por ítem/pedido", "num", "outcome"),
    "Order Region": S("Región de destino del pedido", "cat"),
    "Order State": S("Estado/provincia de destino", "cat"),
    "Order Status": S("Estado del pedido (COMPLETE, PENDING, CLOSED, CANCELED, SUSPECTED_FRAUD, ...)", "cat"),
    "Order Zipcode": S("Código postal del pedido (muy nulo según terceros)", "pii", "pii"),
    "Product Card Id": S("ID de producto", "id", "id"),
    "Product Category Id": S("ID de categoría del producto (parece duplicar Category Id)", "id", "id"),
    "Product Description": S("Descripción del producto (muy nula según terceros)", "text", "text"),
    "Product Image": S("URL de la imagen del producto", "text", "text"),
    "Product Name": S("Nombre del producto", "cat"),
    "Product Price": S("Precio del producto (parece duplicar Order Item Product Price)", "num"),
    "Product Status": S("Estado del producto (constante en 0 según terceros)", "num"),
    "shipping date (DateOrders)": S("Fecha y hora de envío (texto M/D/AAAA H:MM)", "date", "post_event"),
    "Shipping Mode": S("Modo de envío (esperado: Standard Class, First Class, Second Class, Same Day)", "cat"),
}
C = {
    "type": "Type", "real": "Days for shipping (real)", "sched": "Days for shipment (scheduled)",
    "benefit": "Benefit per order", "spc": "Sales per customer", "dstatus": "Delivery Status",
    "late": "Late_delivery_risk", "catid": "Category Id", "cat": "Category Name", "ccity": "Customer City",
    "ccountry": "Customer Country", "cseg": "Customer Segment", "cstate": "Customer State", "cid": "Customer Id",
    "depid": "Department Id", "dep": "Department Name", "lat": "Latitude", "lon": "Longitude", "market": "Market",
    "ocity": "Order City", "ocountry": "Order Country", "ocid": "Order Customer Id", "odate": "order date (DateOrders)",
    "oid": "Order Id", "cardprod": "Order Item Cardprod Id", "disc": "Order Item Discount",
    "rate": "Order Item Discount Rate", "itemid": "Order Item Id", "iprice": "Order Item Product Price",
    "pratio": "Order Item Profit Ratio", "qty": "Order Item Quantity", "sales": "Sales", "total": "Order Item Total",
    "profit": "Order Profit Per Order", "region": "Order Region", "ostate": "Order State", "ostatus": "Order Status",
    "pcard": "Product Card Id", "pcat": "Product Category Id", "pname": "Product Name", "pprice": "Product Price",
    "pstatus": "Product Status", "sdate": "shipping date (DateOrders)", "smode": "Shipping Mode",
    "pdesc": "Product Description", "pimg": "Product Image",
}
EXPECTED_DOMAINS = {  # según documentación de terceros / uso común; verificar contra DescriptionDataCoSupplyChain.csv
    "Type": {"DEBIT", "TRANSFER", "CASH", "PAYMENT"},
    "Delivery Status": {"Advance shipping", "Late delivery", "Shipping canceled", "Shipping on time"},
    "Shipping Mode": {"Standard Class", "First Class", "Second Class", "Same Day"},
    "Customer Segment": {"Consumer", "Corporate", "Home Office"},
    "Market": {"LATAM", "Europe", "Pacific Asia", "USCA", "Africa"},
    "Order Status": {"COMPLETE", "PENDING", "CLOSED", "PENDING_PAYMENT", "CANCELED", "PROCESSING",
                     "SUSPECTED_FRAUD", "ON_HOLD", "PAYMENT_REVIEW"},
}
HYPOTHESES = [  # (a, b, signo esperado, justificación)
    ("Days for shipment (scheduled)", "Late_delivery_risk", "-", "más días programados -> más holgura -> menos atraso"),
    ("Days for shipping (real)", "Late_delivery_risk", "+", "más días reales -> más atraso"),
    ("Days for shipping (real)", "Days for shipment (scheduled)", "+", "envíos programados más largos tardan más"),
    ("Order Item Discount Rate", "Order Item Profit Ratio", "-", "más descuento -> menor margen"),
    ("Order Item Discount", "Order Profit Per Order", "-", "más descuento -> menor ganancia"),
    ("Order Item Quantity", "Sales", "+", "más cantidad -> más ventas"),
    ("Order Item Product Price", "Sales", "+", "más precio -> más ventas"),
    ("Sales", "Order Profit Per Order", "+", "más ventas -> más ganancia"),
    ("Order Item Product Price", "Order Profit Per Order", "+", "productos más caros dejan más ganancia absoluta"),
    ("Order Item Quantity", "Order Item Discount", "+", "más cantidad -> descuento absoluto mayor"),
    ("_ship_lag_days", "Days for shipping (real)", "+", "la demora entre fechas debería reflejar los días reales"),
    ("Late_delivery_risk", "Order Item Profit Ratio", "-", "atrasos suelen asociarse a menor rentabilidad"),
]


# ----------------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------------
def clean(o, nd=4):
    if o is pd.NaT or o is None:
        return None
    if isinstance(o, dict):
        return {str(k): clean(v, nd) for k, v in o.items()}
    if isinstance(o, (list, tuple, set)):
        return [clean(v, nd) for v in o]
    if isinstance(o, (bool, np.bool_)):
        return bool(o)
    if isinstance(o, (int, np.integer)):
        return int(o)
    if isinstance(o, (float, np.floating)):
        f = float(o)
        return None if (math.isnan(f) or math.isinf(f)) else round(f, nd)
    if isinstance(o, pd.Period):
        return str(o)
    if isinstance(o, (pd.Timestamp, datetime)):
        return None if pd.isna(o) else o.isoformat()
    return o


def num_stats(s):
    s = pd.to_numeric(s, errors="coerce").dropna()
    if s.empty:
        return {"count": 0}
    q = s.quantile([0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99])
    iqr = q.loc[0.75] - q.loc[0.25]
    lo, hi = q.loc[0.25] - 1.5 * iqr, q.loc[0.75] + 1.5 * iqr
    return {"count": int(s.size), "mean": s.mean(), "std": s.std(), "min": s.min(), "p1": q.loc[0.01],
            "p5": q.loc[0.05], "p25": q.loc[0.25], "median": q.loc[0.5], "p75": q.loc[0.75], "p95": q.loc[0.95],
            "p99": q.loc[0.99], "max": s.max(), "skew": s.skew(), "kurtosis": s.kurt(),
            "outliers_iqr": int(((s < lo) | (s > hi)).sum())}


def value_counts(s, top=None):
    vc = s.value_counts(dropna=False)
    if top:
        vc = vc.head(top)
    return {str(k): {"n": int(v), "pct": round(100 * v / len(s), 2)} for k, v in vc.items()}


def records(df):
    return df.reset_index().to_dict("records") if (df.index.name or isinstance(df.index, pd.MultiIndex)) \
        else df.to_dict("records")


def corr_ratio(x, groups):
    d = pd.DataFrame({"x": np.asarray(x, dtype=float), "g": np.asarray(groups)}).dropna()
    if len(d) < 3:
        return None
    tot = ((d.x - d.x.mean()) ** 2).sum()
    if tot == 0:
        return None
    gm = d.groupby("g").x.agg(["count", "mean"])
    return float((gm["count"] * (gm["mean"] - d.x.mean()) ** 2).sum() / tot)


def auc_binary(x, y):
    """AUC de x como puntaje para y in {0,1} (Mann-Whitney por rangos)."""
    d = pd.DataFrame({"x": pd.to_numeric(x, errors="coerce"), "y": y}).dropna()
    n1, n0 = int((d.y == 1).sum()), int((d.y == 0).sum())
    if n1 == 0 or n0 == 0 or d.x.nunique() < 2:
        return None
    r = d.x.rank()
    return float((r[d.y == 1].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))


def gini(values):
    v = np.sort(np.asarray(values, dtype=float))
    v = v[v >= 0]
    if v.size == 0 or v.sum() == 0:
        return None
    n = v.size
    cum = np.cumsum(v)
    return float((n + 1 - 2 * (cum / cum[-1]).sum()) / n)


def concentration(values):
    v = np.sort(np.asarray(values, dtype=float))[::-1]
    v = v[v > 0]
    tot = v.sum()
    if tot == 0 or v.size == 0:
        return {}
    sh = v / tot
    n = v.size
    return {"n_entities": int(n), "top1_share_pct": 100 * sh[:1].sum(), "top10_share_pct": 100 * sh[:10].sum(),
            "top_10pct_entities_share_pct": 100 * sh[:max(1, n // 10)].sum(),
            "top_20pct_entities_share_pct": 100 * sh[:max(1, n // 5)].sum(),
            "entities_for_80pct": int(np.searchsorted(np.cumsum(sh), 0.8) + 1),
            "hhi": float((sh ** 2).sum() * 10000), "gini": gini(v)}


def dig(d, *path, default=None):
    for k in path:
        if isinstance(d, dict) and k in d:
            d = d[k]
        elif isinstance(d, list) and isinstance(k, int) and k < len(d):
            d = d[k]
        else:
            return default
    return d


def pick(rows, cols):
    return [{c: r.get(c) for c in cols} for r in (rows or []) if isinstance(r, dict)]


def safe(name, fn, out):
    try:
        out[name] = fn()
    except Exception as e:  # una sección rota no debe tumbar el resto
        out[name] = {"error": f"{type(e).__name__}: {e}", "trace": traceback.format_exc(limit=3)}
        print(f"[WARN] sección '{name}' falló: {e}", file=sys.stderr)


def need(df, *cols):
    m = [c for c in cols if c not in df.columns]
    return {"skipped": f"faltan columnas: {m}"} if m else None


def norm(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


CANON = {norm(c): c for c in SPEC}


# ----------------------------------------------------------------------------
# Carga
# ----------------------------------------------------------------------------
def find_csv(path):
    if os.path.isdir(path):
        files = sorted(glob.glob(os.path.join(path, "*.csv")))
        main = [f for f in files if "dataco" in os.path.basename(f).lower()
                and not any(x in os.path.basename(f).lower() for x in ("description", "token", "access"))]
        pool = main or [f for f in files if not any(x in os.path.basename(f).lower()
                                                    for x in ("description", "token", "access"))]
        if not pool:
            sys.exit(f"No se encontró el CSV principal en {path}")
        return pool[0]
    if not os.path.exists(path):
        sys.exit(f"No existe: {path}")
    return path


def read_csv_any(path, **kw):
    for enc in ("utf-8", "latin-1"):
        try:
            return pd.read_csv(path, encoding=enc, low_memory=False, **kw), enc
        except UnicodeDecodeError:
            continue
    sys.exit(f"No se pudo leer {path} (probé utf-8 y latin-1)")


def parse_dates(s):
    p = pd.to_datetime(s, format="%m/%d/%Y %H:%M", errors="coerce")
    if p.isna().mean() > 0.5:
        p2 = pd.to_datetime(s, errors="coerce")
        if p2.isna().mean() < p.isna().mean():
            p = p2
    return p


def load(path):
    notes = []
    df, enc = read_csv_any(path)
    df = df.rename(columns={c: CANON[norm(c)] for c in df.columns if norm(c) in CANON and CANON[norm(c)] != c})
    missing = [c for c in SPEC if c not in df.columns]
    extra = [c for c in df.columns if c not in SPEC]
    if missing:
        notes.append(f"Columnas esperadas ausentes: {missing}")
    if extra:
        notes.append(f"Columnas no esperadas presentes: {extra}")
    for c, sp in SPEC.items():
        if c in df.columns and sp["kind"] == "date":
            before = df[c].notna().sum()
            df[c] = parse_dates(df[c])
            lost = int(before - df[c].notna().sum())
            if lost:
                notes.append(f"{c}: {lost} fechas no parseables (NaT)")
        elif c in df.columns and sp["kind"] in ("num", "bin"):
            conv = pd.to_numeric(df[c], errors="coerce")
            lost = int(conv.isna().sum() - df[c].isna().sum())
            if lost:
                notes.append(f"{c}: {lost} valores no numéricos convertidos a NaN")
            df[c] = conv
    df["_row_order"] = np.arange(len(df))
    if C["odate"] in df.columns:
        df = df.sort_values(C["odate"], kind="stable").reset_index(drop=True)
        od = df[C["odate"]]
        df["_order_ts"] = od
        df["_order_month"] = od.dt.to_period("M").astype(str)
        df["_order_year"], df["_order_monthnum"] = od.dt.year, od.dt.month
        df["_order_hour"], df["_order_dow"] = od.dt.hour, od.dt.dayofweek
        if C["sdate"] in df.columns:
            df["_ship_lag_days"] = (df[C["sdate"]] - od).dt.total_seconds() / 86400
    if C["real"] in df.columns and C["sched"] in df.columns:
        df["_gap_days"] = df[C["real"]] - df[C["sched"]]
        df["_real_gt_sched"] = np.where(df[C["real"]].notna() & df[C["sched"]].notna(),
                                        (df[C["real"]] > df[C["sched"]]).astype(float), np.nan)
    if C["profit"] in df.columns:
        df["_is_loss"] = np.where(df[C["profit"]].notna(), (df[C["profit"]] < 0).astype(float), np.nan)
    return df, notes, enc


def num_cols(df):
    return [c for c, sp in SPEC.items() if sp["kind"] in ("num", "bin") and c in df.columns]


def has(df, *names):
    return all(n in df.columns for n in names)


# ----------------------------------------------------------------------------
# Secciones
# ----------------------------------------------------------------------------
def sec_metadata(df, path, notes, enc):
    ts = df["_order_ts"] if "_order_ts" in df.columns else None
    return {"generated_at": datetime.now().isoformat(timespec="seconds"), "file": os.path.basename(path),
            "file_size_mb": round(os.path.getsize(path) / 1e6, 2), "encoding_used": enc,
            "rows": len(df), "cols": len([c for c in df.columns if not c.startswith("_")]),
            "order_date_range": {"first": ts.min(), "last": ts.max()} if ts is not None else None,
            "notes": notes,
            "methodology": {
                "grain": "1 fila = 1 ítem de pedido (verificar en structure)",
                "pii": "los datos personales no se imprimen; solo se auditan",
                "expected_domains": "provienen de documentación de terceros; verificar con el diccionario oficial",
                "late_delivery_risk": "se evalúa si es función exacta de días reales vs. programados (ver leakage)",
                "ml_baseline": "corte temporal; compara features honestas contra features que filtran el resultado",
                "caveats": ["Descripciones de columnas inferidas de sus nombres si no se pasa --description.",
                            "Los indicadores de realismo son pistas, no pruebas."]}}


def identical_groups(df, cols):
    sig = {}
    for c in cols:
        s = df[c]
        if pd.api.types.is_numeric_dtype(s):
            v = s.astype("float64")
        elif pd.api.types.is_datetime64_any_dtype(s):
            v = s.astype("int64")
        else:
            v = s.astype(str)
        h = int(pd.util.hash_pandas_object(v, index=False).sum() % (2 ** 62))
        sig.setdefault(h, []).append((c, v))
    groups = []
    for items in sig.values():
        if len(items) < 2:
            continue
        base_c, base_v = items[0]
        same = [base_c] + [c for c, v in items[1:] if base_v.equals(v)]
        if len(same) > 1:
            groups.append(same)
    return groups


def sec_quality(df):
    cols = {}
    real_cols = [c for c in df.columns if not c.startswith("_")]
    for c in real_cols:
        s = df[c]
        sp = SPEC.get(c, {"kind": None, "role": "feature"})
        info = {"dtype": str(s.dtype), "role": sp["role"], "nulls": int(s.isna().sum()),
                "null_pct": round(100 * s.isna().mean(), 3), "nunique": int(s.nunique(dropna=True)),
                "unique_ratio": round(s.nunique(dropna=True) / max(len(s), 1), 4)}
        kind = sp["kind"]
        if kind == "pii" or kind == "text":
            pass  # sin valores
        elif kind in ("num", "bin") or (kind is None and pd.api.types.is_numeric_dtype(s)):
            info["stats"] = num_stats(s)
            info["is_constant"] = bool(s.nunique(dropna=True) <= 1)
            info["zero_pct"] = 100 * (s == 0).mean()
            info["negative_pct"] = 100 * (s < 0).mean()
            rng = s.max() - s.min()
            if pd.notna(rng) and rng > 0:
                e = EDGE_FRAC * rng
                info["pct_at_min_edge"], info["pct_at_max_edge"] = 100 * (s <= s.min() + e).mean(), 100 * (s >= s.max() - e).mean()
        elif pd.api.types.is_datetime64_any_dtype(s):
            info["min"], info["max"] = s.min(), s.max()
        elif kind == "id":
            info["is_unique_key"] = bool(s.nunique() == len(s))
        else:
            info["top_values"] = value_counts(s, top=15 if info["nunique"] <= 60 else 8)
        cols[c] = info
    ident = identical_groups(df, [c for c in real_cols if SPEC.get(c, {}).get("kind") != "pii"])
    K["identical_groups"] = len(ident)
    const = [c for c, i in cols.items() if i.get("is_constant") or i["nunique"] <= 1]
    highnull = {c: i["null_pct"] for c, i in cols.items() if i["null_pct"] > 50}
    K["constant_cols"], K["highnull_cols"] = const, list(highnull)
    ws = {}
    for c in real_cols:
        if SPEC.get(c, {}).get("kind") == "cat" and not pd.api.types.is_numeric_dtype(df[c]):
            u = pd.Series(df[c].dropna().astype(str).unique())
            n = int((u != u.str.strip()).sum())
            if n:
                ws[c] = n
    K["untrimmed_cols"] = ws
    return {"rows": len(df), "memory_mb": round(df.memory_usage(deep=True).sum() / 1e6, 2),
            "duplicate_rows": int(df[real_cols].duplicated().sum()),
            "constant_columns": const, "columns_over_50pct_null": highnull, "columns_with_untrimmed_text": ws,
            "identical_column_groups": ident,
            "columns_edge_saturation_over_2pct": {c: round(max(i.get("pct_at_min_edge", 0), i.get("pct_at_max_edge", 0)), 2)
                                                  for c, i in cols.items() if max(i.get("pct_at_min_edge", 0),
                                                                                  i.get("pct_at_max_edge", 0)) > 2},
            "columns": cols}


def sec_pii(df):
    out = {}
    for c, sp in SPEC.items():
        if sp["kind"] != "pii" or c not in df.columns:
            continue
        s = df[c].dropna().astype(str)
        uniq = pd.Series(s.unique())
        sample = uniq.sample(min(1000, len(uniq)), random_state=0) if len(uniq) else uniq
        top = s.value_counts(normalize=True).iloc[0] * 100 if len(s) else None
        out[c] = {"null_pct": round(100 * df[c].isna().mean(), 2), "nunique": int(s.nunique()),
                  "top_value_share_pct": top,
                  "pct_values_masked_like_xxx": float(100 * sample.str.fullmatch(r"[Xx*#\-]+").mean()) if len(sample) else None,
                  "pct_values_with_at_sign": float(100 * sample.str.contains("@", regex=False).mean()) if len(sample) else None}
    masked = [c for c, i in out.items() if (i.get("pct_values_masked_like_xxx") or 0) > 90 or (i.get("top_value_share_pct") or 0) > 90]
    K["pii_cols"], K["pii_masked"] = list(out), masked
    return {"columns": out, "columns_that_look_masked": masked,
            "note": "No se imprime ningún valor. 'masked_like_xxx' indica contenido tipo XXXX (enmascarado).",
            "recommendation": "Excluir estas columnas de cualquier modelo o reporte."}


def sec_structure(df):
    r = need(df, C["oid"])
    if r:
        return r
    oid = C["oid"]
    per_order = df.groupby(oid).size()
    out = {"rows": len(df), "orders": int(per_order.size), "items_per_order": num_stats(per_order),
           "items_per_order_distribution": value_counts(per_order.clip(upper=10), top=10),
           "orders_with_multiple_items_pct": 100 * (per_order > 1).mean()}
    K["n_orders"] = int(per_order.size)
    if C["itemid"] in df.columns:
        out["order_item_id_is_unique"] = bool(df[C["itemid"]].is_unique)
    chk = [c for c in (C["odate"], C["smode"], C["dstatus"], C["ostatus"], C["type"], C["cid"], C["late"],
                       C["market"], C["region"]) if c in df.columns]
    if chk:
        nun = df.groupby(oid)[chk].nunique(dropna=False)
        out["within_order_inconsistency_pct"] = {c: float(100 * (nun[c] > 1).mean()) for c in chk}

    def same_values(a, b):
        if pd.api.types.is_numeric_dtype(df[a]) and pd.api.types.is_numeric_dtype(df[b]):
            d = (df[a] - df[b]).abs().dropna()
            return bool((d < 1e-9).all()) and len(d) > 0
        return bool(df[a].astype(str).eq(df[b].astype(str)).all())

    pairs = [("catid", "cat"), ("depid", "dep"), ("pcard", "pname"), ("pcat", "catid"), ("cardprod", "pcard"),
             ("ocid", "cid"), ("iprice", "pprice")]
    maps = {}
    for a, b in pairs:
        A, B = C[a], C[b]
        if A not in df.columns or B not in df.columns:
            continue
        x = df[[A, B]].dropna()
        ab, ba = x.groupby(A)[B].nunique(), x.groupby(B)[A].nunique()
        ex = {}
        if (ba > 1).any():
            ex["b_values_with_multiple_a_examples"] = [str(v) for v in ba[ba > 1].index[:5]]
        if (ab > 1).any():
            ex["a_values_with_multiple_b_examples"] = [str(v) for v in ab[ab > 1].index[:5]]
        maps[f"{A} <-> {B}"] = {"a_nunique": int(ab.size), "b_nunique": int(ba.size),
                                "a_with_multiple_b": int((ab > 1).sum()), "b_with_multiple_a": int((ba > 1).sum()),
                                "identical_row_by_row": same_values(A, B), **ex}
    out["column_mappings"] = maps
    return out


def sec_declared_vs_observed(df):
    res, issues = {}, {"unexpected_values": {}, "missing_expected_values": {}, "numeric_problems": {}}
    for c, exp in EXPECTED_DOMAINS.items():
        if c not in df.columns:
            continue
        obs = set(df[c].dropna().astype(str).unique())
        unexpected, absent = sorted(obs - exp), sorted(exp - obs)
        res[c] = {"expected": sorted(exp), "observed": value_counts(df[c]), "unexpected_values": unexpected,
                  "expected_values_not_observed": absent}
        if unexpected:
            issues["unexpected_values"][c] = unexpected
        if absent:
            issues["missing_expected_values"][c] = absent
    num = {}
    if C["late"] in df.columns:
        v = set(df[C["late"]].dropna().unique())
        num[C["late"]] = {"observed_values": sorted(v), "is_binary_0_1": v <= {0, 1, 0.0, 1.0}}
        if not v <= {0, 1}:
            issues["numeric_problems"][C["late"]] = "no es binaria 0/1"
    rules = [(C["rate"], 0, 1, "tasa de descuento fuera de [0,1]"), (C["qty"], 1, None, "cantidad < 1"),
             (C["iprice"], 0.0001, None, "precio <= 0"), (C["real"], 0, None, "días reales < 0"),
             (C["sched"], 0, None, "días programados < 0"), (C["lat"], -90, 90, "latitud fuera de rango"),
             (C["lon"], -180, 180, "longitud fuera de rango"), (C["sales"], 0, None, "ventas < 0")]
    for c, lo, hi, msg in rules:
        if c not in df.columns:
            continue
        s = df[c].dropna()
        bad = int((s < lo).sum() + ((s > hi).sum() if hi is not None else 0))
        num[c] = {"min": s.min(), "max": s.max(), "n_violations": bad}
        if bad:
            issues["numeric_problems"][c] = f"{bad} filas: {msg}"
    if C["pstatus"] in df.columns:
        num[C["pstatus"]] = {"distinct_values": sorted(df[C["pstatus"]].dropna().unique().tolist())[:10]}
    K["domain_issues"] = {**issues["unexpected_values"], **issues["numeric_problems"]}
    return {"domains": res, "numeric_checks": num, "issues": issues,
            "note": "Los dominios esperados vienen de documentación de terceros; confirmar con DescriptionDataCoSupplyChain.csv."}


def cmp_cols(a, b, tol=0.01, rel=0.0):
    d = (a - b).abs()
    ok = d <= (tol + rel * b.abs())
    m = d.notna()
    n = int(m.sum())
    return {"rows_compared": n, "pct_match": float(100 * ok[m].mean()) if n else None,
            "max_abs_diff": float(d.max()) if n else None, "mean_abs_diff": float(d.mean()) if n else None}


def sec_formulas(df):
    g = lambda k: df[C[k]] if C[k] in df.columns else None  # noqa: E731
    sales, qty, ip, disc, rate, total = g("sales"), g("qty"), g("iprice"), g("disc"), g("rate"), g("total")
    profit, ratio, ben, spc, pp = g("profit"), g("pratio"), g("benefit"), g("spc"), g("pprice")
    res, extra = {}, {}
    if sales is not None and qty is not None and ip is not None:
        res["Sales = precio x cantidad"] = cmp_cols(sales, ip * qty)
    if total is not None and sales is not None and disc is not None:
        res["Order Item Total = Sales - descuento"] = cmp_cols(total, sales - disc)
    if disc is not None and sales is not None and rate is not None:
        res["Descuento = Sales x tasa"] = cmp_cols(disc, sales * rate, tol=0.02, rel=0.005)
    if ratio is not None and profit is not None and total is not None:
        res["Profit ratio = ganancia / Order Item Total"] = cmp_cols(ratio, profit / total.replace(0, np.nan), tol=0.011)
    if ratio is not None and profit is not None and sales is not None:
        res["Profit ratio = ganancia / Sales"] = cmp_cols(ratio, profit / sales.replace(0, np.nan), tol=0.011)
    if ben is not None and profit is not None:
        res["Benefit per order = Order Profit Per Order"] = cmp_cols(ben, profit)
    if spc is not None and total is not None:
        res["Sales per customer = Order Item Total"] = cmp_cols(spc, total)
    if spc is not None and sales is not None:
        res["Sales per customer = Sales"] = cmp_cols(spc, sales)
    if pp is not None and ip is not None:
        res["Product Price = Order Item Product Price"] = cmp_cols(pp, ip)
    if "_ship_lag_days" in df.columns and C["real"] in df.columns:
        lag, real = df["_ship_lag_days"], df[C["real"]]
        res["Días reales = piso(fecha envío - fecha pedido)"] = cmp_cols(real, np.floor(lag), tol=0.0)
        res["Días reales = redondeo(fecha envío - fecha pedido)"] = cmp_cols(real, lag.round(), tol=0.0)
        res["Días reales ~ fecha envío - fecha pedido (tol 1 día)"] = cmp_cols(real, lag, tol=1.0)
    if C["late"] in df.columns and "_real_gt_sched" in df.columns:
        m = df[C["late"]].notna() & df["_real_gt_sched"].notna()
        y, a = df.loc[m, C["late"]], df.loc[m, "_real_gt_sched"]
        ge = (df.loc[m, C["real"]] >= df.loc[m, C["sched"]]).astype(float)
        res["Late_delivery_risk = (días reales > programados)"] = {
            "rows_compared": int(m.sum()), "pct_match": float(100 * (y == a).mean()),
            "pct_match_if_ge": float(100 * (y == ge).mean()),
            "confusion": {"late=1_&_real>sched": int(((y == 1) & (a == 1)).sum()), "late=1_&_real<=sched": int(((y == 1) & (a == 0)).sum()),
                          "late=0_&_real>sched": int(((y == 0) & (a == 1)).sum()), "late=0_&_real<=sched": int(((y == 0) & (a == 0)).sum())}}
        K["late_rule_match"] = max(res["Late_delivery_risk = (días reales > programados)"]["pct_match"],
                                   res["Late_delivery_risk = (días reales > programados)"]["pct_match_if_ge"])
        key_ = "Late_delivery_risk = (días reales > programados)"
        if C["dstatus"] in df.columns:
            nc = m & (df[C["dstatus"]].astype(str).str.strip() != "Shipping canceled")
            res[key_]["rows_excluding_shipping_canceled"] = int(nc.sum())
            res[key_]["pct_match_excluding_shipping_canceled"] = float(
                100 * (df.loc[nc, C["late"]] == df.loc[nc, "_real_gt_sched"]).mean())
            K["late_rule_match_excl"] = res[key_]["pct_match_excluding_shipping_canceled"]
        mm_ = df[(df["_real_gt_sched"] == 1) & (df[C["late"]] == 0)]
        extra["rows_real_gt_sched_but_late_0"] = {"n": int(len(mm_))}
        for k_ in ("dstatus", "ostatus"):
            if C[k_] in df.columns:
                extra["rows_real_gt_sched_but_late_0"][C[k_]] = value_counts(mm_[C[k_]], top=6)
    K["formula_matches"] = sum(1 for k, v in res.items() if (v.get("pct_match") or 0) >= 99
                               and not k.startswith("Late_delivery") and not k.startswith("Días reales"))
    K["formulas"] = {k: round(v.get("pct_match") or 0, 1) for k, v in res.items()}
    return {"checks": res, "late_rule_exceptions": extra, "formulas_matching_99pct": K["formula_matches"],
            "note": "pct_match = % de filas donde la relación se cumple con la tolerancia indicada."}


def group_table(df, by, top=None):
    aggs = {"items": (C["late"], "size"), "late_pct": (C["late"], lambda s: 100 * s.mean())}
    if C["real"] in df.columns:
        aggs["avg_real_days"] = (C["real"], "mean")
    if C["sched"] in df.columns:
        aggs["avg_scheduled_days"] = (C["sched"], "mean")
    if "_gap_days" in df.columns:
        aggs["avg_gap_days"] = ("_gap_days", "mean")
    t = df.groupby(by, dropna=False).agg(**aggs).sort_values("items", ascending=False)
    t["pct_items"] = 100 * t["items"] / len(df)
    return t.head(top) if top else t


def sec_delivery(df):
    r = need(df, C["late"])
    if r:
        return r
    late = C["late"]
    out = {"items": len(df), "late_delivery_risk_pct": 100 * df[late].mean()}
    K["late_pct"] = float(100 * df[late].mean())
    if C["real"] in df.columns:
        out["days_real_stats"] = num_stats(df[C["real"]])
    if C["sched"] in df.columns:
        out["days_scheduled_stats"] = num_stats(df[C["sched"]])
    if "_gap_days" in df.columns:
        out["gap_days_real_minus_scheduled_stats"] = num_stats(df["_gap_days"])
        gp = df["_gap_days"].round()
        if gp.nunique() <= 30:
            t = df.groupby(gp).agg(items=(late, "size"), late_pct=(late, lambda s: 100 * s.mean()))
            out["late_pct_by_gap_days"] = records(t.round(3).rename_axis("gap_days"))
    tables = {}
    for k in ("smode", "market", "region", "cseg", "dep", "cat", "type", "ostatus", "dstatus"):
        if C[k] in df.columns:
            tables[C[k]] = records(group_table(df, C[k]).round(3))
    if C["ocountry"] in df.columns:
        tables[C["ocountry"] + " (top 25)"] = records(group_table(df, C["ocountry"], top=25).round(3))
    out["by_group"] = tables
    if has(df, C["smode"], C["sched"]):
        out["by_shipping_mode_and_scheduled_days"] = records(
            df.groupby([C["smode"], C["sched"]]).agg(items=(late, "size"), late_pct=(late, lambda s: 100 * s.mean()))
            .round(3))
    if C["smode"] in df.columns and C["real"] in df.columns:
        out["real_days_by_shipping_mode"] = {str(k): num_stats(v[C["real"]]) for k, v in df.groupby(C["smode"])}
    if C["dstatus"] in df.columns:
        ct = pd.crosstab(df[C["dstatus"]], df[late])
        out["delivery_status_vs_late_risk_counts"] = ct.to_dict("index")
        out["late_risk_pct_by_delivery_status"] = {str(k): float(100 * v) for k, v in df.groupby(C["dstatus"])[late].mean().items()}
        out["delivery_status_distribution"] = value_counts(df[C["dstatus"]])
    if "_order_month" in df.columns:
        m = df.groupby("_order_month").agg(items=(late, "size"), late_pct=(late, lambda s: 100 * s.mean()))
        out["late_pct_by_order_month"] = m.round(3).to_dict("index")
    if C["smode"] in df.columns:
        t = group_table(df, C["smode"])
        K["worst_mode"] = (str(t["late_pct"].idxmax()), float(t["late_pct"].max()))
        K["best_mode"] = (str(t["late_pct"].idxmin()), float(t["late_pct"].min()))
    return out


def sp_table(df, by, top=None):
    aggs = {"items": (C["sales"], "size"), "sales": (C["sales"], "sum"), "profit": (C["profit"], "sum"),
            "loss_pct": ("_is_loss", lambda s: 100 * s.mean())}
    if C["rate"] in df.columns:
        aggs["avg_discount_rate"] = (C["rate"], "mean")
    t = df.groupby(by, dropna=False).agg(**aggs).sort_values("sales", ascending=False)
    t["margin_pct"] = 100 * t["profit"] / t["sales"].replace(0, np.nan)
    t["sales_share_pct"] = 100 * t["sales"] / t["sales"].sum()
    return t.head(top) if top else t


def find_level_shifts(s, win=6, thr=0.30):
    """Primer mes donde la serie se aleja > thr de la mediana de los `win` meses previos y se mantiene al mes siguiente."""
    s = s.replace([np.inf, -np.inf], np.nan).dropna()
    vals, idx, out, i = s.values, list(s.index), [], win
    while i < len(vals) - 1:
        base = float(np.median(vals[i - win:i]))
        if base and abs(vals[i] / base - 1) > thr and abs(vals[i + 1] / base - 1) > thr:
            after = float(np.median(vals[i:min(i + win, len(vals))]))
            out.append({"month": idx[i], "before_median": base, "after_median": after, "pct_change": 100 * (after / base - 1)})
            i += win
        else:
            i += 1
    return out


def sec_sales_profit(df):
    r = need(df, C["sales"], C["profit"])
    if r:
        return r
    sales, profit = df[C["sales"]], df[C["profit"]]
    K["sales_total"], K["profit_total"] = float(sales.sum()), float(profit.sum())
    K["margin_pct"] = float(100 * profit.sum() / sales.sum()) if sales.sum() else None
    K["loss_item_pct"] = float(100 * (profit < 0).mean())
    out = {"sales_total": sales.sum(), "profit_total": profit.sum(), "margin_pct": K["margin_pct"],
           "loss_making_items_pct": K["loss_item_pct"], "loss_total": profit[profit < 0].sum(),
           "profit_stats": num_stats(profit), "sales_stats": num_stats(sales)}
    if C["pratio"] in df.columns:
        out["profit_ratio_stats"] = num_stats(df[C["pratio"]])
    if C["rate"] in df.columns:
        out["discount_rate_stats"] = num_stats(df[C["rate"]])
        b = pd.cut(df[C["rate"]], [-0.001, 0, 0.05, 0.10, 0.15, 0.20, 0.25, 1.0])
        t = df.groupby(b, observed=True).agg(items=(C["sales"], "size"), avg_profit=(C["profit"], "mean"),
                                             loss_pct=("_is_loss", lambda s: 100 * s.mean()))
        if C["pratio"] in df.columns:
            t["avg_profit_ratio"] = df.groupby(b, observed=True)[C["pratio"]].mean()
        out["by_discount_rate_bin"] = records(t.round(3).rename_axis("discount_rate_bin").reset_index()
                                              .assign(discount_rate_bin=lambda x: x["discount_rate_bin"].astype(str)).set_index("discount_rate_bin"))
        out["discount_rate_vs_profit_spearman"] = float(df[C["rate"]].corr(profit, method="spearman"))
    if C["qty"] in df.columns:
        out["quantity_distribution"] = value_counts(df[C["qty"]], top=10)
    tables = {}
    for k in ("cat", "dep", "market", "region", "smode", "cseg", "type", "ostatus"):
        if C[k] in df.columns:
            tables[C[k]] = records(sp_table(df, C[k]).round(3))
    out["by_group"] = tables
    if C["cat"] in df.columns:
        t = sp_table(df, C["cat"])
        out["top5_categories_by_profit"] = records(t.nlargest(5, "profit").round(2))
        out["bottom5_categories_by_profit"] = records(t.nsmallest(5, "profit").round(2))
        out["category_sales_concentration"] = concentration(t["sales"].values)
        K["top_cat"] = (str(t.index[0]), float(t["sales_share_pct"].iloc[0]))
    if C["pname"] in df.columns:
        pt = df.groupby(C["pname"]).agg(sales=(C["sales"], "sum"), profit=(C["profit"], "sum"), items=(C["sales"], "size"))
        out["product_sales_concentration"] = concentration(pt["sales"].values)
        out["top10_products_by_sales"] = records(pt.nlargest(10, "sales").round(2))
        out["bottom10_products_by_profit"] = records(pt.nsmallest(10, "profit").round(2))
        out["products_with_total_loss_pct"] = float(100 * (pt["profit"] < 0).mean())
    if C["oid"] in df.columns and C["total"] in df.columns:
        o = df.groupby(C["oid"]).agg(order_total=(C["total"], "sum"), order_profit=(C["profit"], "sum"))
        out["order_value_stats"] = num_stats(o["order_total"])
        out["order_profit_stats"] = num_stats(o["order_profit"])
        out["loss_making_orders_pct"] = float(100 * (o["order_profit"] < 0).mean())
    if "_order_month" in df.columns:
        g = df.groupby("_order_month")
        m = pd.DataFrame({"items": g.size(), "sales": g[C["sales"]].sum(), "profit": g[C["profit"]].sum()})
        if C["oid"] in df.columns:
            m["orders"] = g[C["oid"]].nunique()
        m["margin_pct"] = 100 * m["profit"] / m["sales"].replace(0, np.nan)
        if C["late"] in df.columns:
            m["late_pct"] = 100 * g[C["late"]].mean()
        idx = pd.period_range(pd.Period(m.index.min()), pd.Period(m.index.max()), freq="M").astype(str)
        mm = m.reindex(idx)
        ok = (mm["items"] >= MIN_MONTH_ITEMS) & (mm["items"].shift(1) >= MIN_MONTH_ITEMS)
        m["sales_mom_pct"] = ((mm["sales"] / mm["sales"].shift(1) - 1) * 100).where(ok).reindex(m.index)
        m["partial_coverage"] = m["items"] < MIN_MONTH_ITEMS
        if "orders" in m.columns:
            m["items_per_order"] = m["items"] / m["orders"]
        m["avg_sales_per_item"] = m["sales"] / m["items"]
        shifts = {}
        for met in ("items", "items_per_order", "avg_sales_per_item"):
            if met in m.columns:
                sh = find_level_shifts(m[met])
                if sh:
                    shifts[met] = sh
        out["monthly_level_shifts"] = shifts
        out["growth_note"] = "Si hay quiebres de nivel, la mediana de crecimiento mensual no es representativa: comparar períodos por separado."
        K["level_shifts"] = shifts
        out["monthly"] = records(m.round(3).rename_axis("month"))
        out["median_monthly_sales_growth_pct"] = float(m["sales_mom_pct"].median()) if m["sales_mom_pct"].notna().any() else None
        out["months_with_partial_coverage"] = m.index[m["partial_coverage"]].tolist()
        out["calendar_months_missing_in_range"] = [i for i in idx if i not in m.index]
        yr = df.groupby("_order_year").agg(items=(C["sales"], "size"), sales=(C["sales"], "sum"), profit=(C["profit"], "sum"))
        out["yearly"] = yr.round(2).to_dict("index")
    return out


def sec_geography(df):
    out = {}
    for k in ("market", "region", "ocountry", "ostate", "ocity", "ccountry", "cstate", "ccity"):
        c = C[k]
        if c in df.columns:
            out[f"{c} (top 20)"] = value_counts(df[c], top=20)
            out[f"{c} n_unique"] = int(df[c].nunique())
    if has(df, C["ccountry"], C["ocountry"]):
        out["customer_country_differs_from_order_country_pct"] = float(
            100 * (df[C["ccountry"]].astype(str) != df[C["ocountry"]].astype(str)).mean())
        out["customer_country_examples_top5"] = value_counts(df[C["ccountry"]], top=5)
    if has(df, C["lat"], C["lon"]):
        la, lo = df[C["lat"]], df[C["lon"]]
        out["lat_stats"], out["lon_stats"] = num_stats(la), num_stats(lo)
        out["unique_coordinate_pairs"] = int(df[[C["lat"], C["lon"]]].drop_duplicates().shape[0])
        out["pct_lat_lon_both_zero"] = float(100 * ((la == 0) & (lo == 0)).mean())
        out["pct_lon_positive"] = float(100 * (lo > 0).mean())
        out["note"] = "Latitude/Longitude: semántica no documentada; contrastar con país/ciudad de cliente y de pedido."
    if C["market"] in df.columns and C["sales"] in df.columns:
        t = df.groupby(C["market"])[C["sales"]].sum()
        out["sales_share_by_market_pct"] = (100 * t / t.sum()).round(2).to_dict()
    return out


def sec_customers(df):
    r = need(df, C["cid"], C["oid"])
    if r:
        return r
    cid, oid = C["cid"], C["oid"]
    orders = df.groupby(cid)[oid].nunique()
    K["n_customers"] = int(orders.size)
    K["repeat_pct"] = float(100 * (orders > 1).mean())
    out = {"customers": int(orders.size), "orders_per_customer": num_stats(orders),
           "orders_per_customer_distribution": value_counts(orders.clip(upper=10), top=10),
           "repeat_customers_pct": K["repeat_pct"], "items_per_customer": num_stats(df.groupby(cid).size())}
    if C["total"] in df.columns:
        spend = df.groupby(cid)[C["total"]].sum()
        out["spend_per_customer"] = num_stats(spend)
        out["spend_concentration"] = concentration(spend.values)
    if C["cseg"] in df.columns:
        out["customers_by_segment"] = value_counts(df.drop_duplicates(cid)[C["cseg"]])
        n = df.groupby(cid)[C["cseg"]].nunique()
        out["customers_with_multiple_segments_pct"] = float(100 * (n > 1).mean())
        if C["total"] in df.columns:
            out["avg_spend_by_segment"] = df.groupby(C["cseg"])[C["total"]].sum().div(
                df.groupby(C["cseg"])[cid].nunique()).round(2).to_dict()
    if "_order_ts" in df.columns:
        first = df.groupby(cid)["_order_ts"].min()
        last = df.groupby(cid)["_order_ts"].max()
        ref = df["_order_ts"].max()
        out["recency_days"] = num_stats((ref - last).dt.days)
        coh = pd.DataFrame({"cohort": first.dt.to_period("M").astype(str), "repeat": orders > 1})
        t = coh.groupby("cohort").agg(size=("repeat", "size"), repeat_pct=("repeat", lambda s: 100 * s.mean()))
        out["first_order_cohorts_min200"] = records(t[t["size"] >= 200].round(3).rename_axis("cohort"))
        q_ = pd.DataFrame({"q": first.dt.to_period("Q").astype(str), "repeat": orders > 1})
        tq = q_.groupby("q").agg(size=("repeat", "size"), repeat_pct=("repeat", lambda s: 100 * s.mean()))
        out["repeat_pct_by_first_order_quarter"] = records(tq.round(2).rename_axis("quarter"))
    return out


def sec_products(df):
    out = {}
    pc = C["pcard"] if C["pcard"] in df.columns else C["pname"]
    if pc not in df.columns:
        return {"skipped": "faltan columnas de producto"}
    out["n_products"] = int(df[pc].nunique())
    if C["cat"] in df.columns:
        out["n_categories"] = int(df[C["cat"]].nunique())
    if C["dep"] in df.columns:
        out["n_departments"] = int(df[C["dep"]].nunique())
        if C["cat"] in df.columns:
            out["categories_per_department"] = df.groupby(C["dep"])[C["cat"]].nunique().to_dict()
    if C["iprice"] in df.columns:
        out["unit_price_stats"] = num_stats(df[C["iprice"]])
        pv = df.groupby(pc)[C["iprice"]].nunique()
        out["products_with_multiple_prices_pct"] = float(100 * (pv > 1).mean())
        out["price_range_per_product_stats"] = num_stats(df.groupby(pc)[C["iprice"]].agg(lambda s: s.max() - s.min()))
    if C["cat"] in df.columns:
        out["products_per_category_top15"] = df.groupby(C["cat"])[pc].nunique().sort_values(ascending=False).head(15).to_dict()
    for c in (C["pstatus"], C["pdesc"], C["pimg"]):
        if c in df.columns:
            out[f"{c} nunique"] = int(df[c].nunique())
            out[f"{c} null_pct"] = float(100 * df[c].isna().mean())
    return out


def sec_orders_status(df):
    out = {}
    for k in ("ostatus", "type", "dstatus"):
        if C[k] in df.columns:
            out[f"{C[k]} distribution"] = value_counts(df[C[k]])
    if has(df, C["dstatus"], C["ostatus"]):
        out["delivery_status_vs_order_status_counts"] = pd.crosstab(df[C["dstatus"]], df[C["ostatus"]]).to_dict("index")
    if C["ostatus"] in df.columns:
        fraud = df[C["ostatus"]].astype(str).str.upper().eq("SUSPECTED_FRAUD")
        out["suspected_fraud_pct"] = float(100 * fraud.mean())
        K["fraud_pct"] = out["suspected_fraud_pct"]
        tmp = df.assign(_fraud=fraud.astype(float))
        by = {}
        for k in ("market", "region", "type", "cseg", "smode"):
            if C[k] in df.columns:
                t = tmp.groupby(C[k])["_fraud"].agg(["size", "mean"])
                t["mean"] *= 100
                by[C[k]] = t.rename(columns={"size": "items", "mean": "fraud_pct"}).round(3).to_dict("index")
        if C["cat"] in df.columns:
            t = tmp.groupby(C["cat"])["_fraud"].agg(["size", "mean"])
            t = t[t["size"] >= 500]
            t["mean"] *= 100
            by[C["cat"] + " (min 500 items)"] = t.rename(columns={"size": "items", "mean": "fraud_pct"}).sort_values(
                "fraud_pct", ascending=False).head(10).round(3).to_dict("index")
        out["suspected_fraud_pct_by_group"] = by
        canc = df[C["ostatus"]].astype(str).str.upper().eq("CANCELED")
        out["canceled_pct"] = float(100 * canc.mean())
        if C["late"] in df.columns:
            out["late_risk_pct_among_canceled"] = float(100 * df.loc[canc, C["late"]].mean()) if canc.any() else None
    if C["type"] in df.columns and C["sales"] in df.columns:
        out["sales_share_by_payment_type_pct"] = (100 * df.groupby(C["type"])[C["sales"]].sum() / df[C["sales"]].sum()).round(2).to_dict()
    return out


def sec_temporal(df):
    r = need(df, "_order_ts")
    if r:
        return r
    ts = df["_order_ts"].dropna()
    days = ts.dt.normalize()
    per_day = days.value_counts().sort_index()
    full = pd.date_range(days.min(), days.max(), freq="D")
    miss = full.difference(per_day.index)
    keys = [c for c in (C["sales"], C["profit"], C["late"], C["qty"], C["rate"], C["real"], C["sched"], C["total"],
                        "_gap_days") if c in df.columns]
    d2 = df.dropna(subset=["_order_ts"])
    cal = {c: {g: corr_ratio(d2[c], d2[g]) for g in ("_order_hour", "_order_dow", "_order_monthnum")} for c in keys}
    rank_t = d2["_order_ts"].rank(method="first")
    trend = {c: float(d2[c].corr(rank_t, method="spearman")) for c in keys}
    K["max_calendar_eta2"] = max([v for e in cal.values() for v in e.values() if v is not None] or [0])
    out = {"first": ts.min(), "last": ts.max(), "calendar_days_in_range": int(len(full)),
           "days_without_orders": int(len(miss)), "days_without_orders_pct": 100 * len(miss) / max(len(full), 1),
           "items_per_day": num_stats(per_day),
           "daily_dispersion_index_var_over_mean": float(per_day.var() / per_day.mean()) if per_day.mean() else None,
           "items_per_year": d2["_order_year"].value_counts().sort_index().to_dict(),
           "items_per_month": d2["_order_month"].value_counts().sort_index().to_dict(),
           "items_by_weekday": d2["_order_dow"].value_counts().sort_index().to_dict(),
           "items_by_hour": d2["_order_hour"].value_counts().sort_index().to_dict(),
           "calendar_effects_eta2": cal, "trend_spearman_vs_time": trend}
    if "_ship_lag_days" in df.columns:
        lag = df["_ship_lag_days"]
        out["ship_lag_days_stats"] = num_stats(lag)
        out["ship_before_order_pct"] = float(100 * (lag < 0).mean())
        out["ship_date_range"] = {"first": df[C["sdate"]].min(), "last": df[C["sdate"]].max()}
    out["items_per_day_largest_gaps_days"] = [int(x) for x in sorted(
        (np.diff(per_day.index.values).astype("timedelta64[D]").astype(int) if len(per_day) > 1 else []), reverse=True)[:5]]
    return out


def sec_correlations(df):
    base = [C[k] for k in ("real", "sched", "benefit", "spc", "late", "disc", "rate", "iprice", "pratio", "qty",
                           "sales", "total", "profit", "pprice", "lat", "lon") if C[k] in df.columns]
    base += [c for c in ("_ship_lag_days", "_gap_days", "_order_hour", "_order_dow", "_order_monthnum") if c in df.columns]
    X = df[base]
    pear, spear = X.corr(), X.corr(method="spearman")
    pairs, dup = [], []
    for i, a in enumerate(base):
        for b in base[i + 1:]:
            r = spear.loc[a, b]
            if pd.notna(r):
                (dup if abs(r) > 0.995 else pairs).append({"a": a, "b": b, "spearman": r, "pearson": pear.loc[a, b]})
    pairs.sort(key=lambda p: -abs(p["spearman"]))
    targets = [c for c in (C["late"], C["profit"]) if c in df.columns]
    leaky = {c for c, sp in SPEC.items() if sp["role"] == "post_event"} | {"_ship_lag_days", "_gap_days"}
    f2t = {}
    for t in targets:
        rows = []
        for f in base:
            if f == t or X[f].nunique() < 2:
                continue
            q = pd.qcut(X[f].rank(method="first"), 10, labels=False, duplicates="drop")
            rows.append({"feature": f, "spearman": spear.loc[f, t], "pearson": pear.loc[f, t],
                         "eta2_deciles": corr_ratio(X[t], q), "auc_vs_target": auc_binary(X[f], X[t]) if t == C["late"] else None,
                         "possible_leak": f in leaky or SPEC.get(f, {}).get("role") == "outcome"})
        rows.sort(key=lambda r: -abs(r["spearman"] or 0))
        f2t[t] = rows
    biz = [c for c in (C["sched"], C["rate"], C["iprice"], C["qty"], C["lat"], C["lon"], "_order_hour", "_order_dow",
                       "_order_monthnum") if c in df.columns]
    vif = None
    try:
        Z = df[biz].dropna()
        Z = Z.loc[:, Z.std() > 0]
        Cm = np.corrcoef(((Z - Z.mean()) / Z.std()).values.T)
        vif = dict(zip(Z.columns, np.diag(np.linalg.inv(Cm)).round(3)))
    except Exception as e:  # noqa: BLE001
        vif = {"error": str(e)}
    return {"columns": base, "spearman_matrix": spear.round(3).to_dict("index"), "pearson_matrix": pear.round(3).to_dict("index"),
            "top25_pairs_by_abs_spearman": pairs[:25], "near_duplicate_pairs_abs_spearman_gt_0_995": dup,
            "features_vs_targets": f2t, "vif_business_features": vif}


def sec_hypotheses(df):
    cols = [c for c in set(x for h in HYPOTHESES for x in h[:2]) if c in df.columns]
    sp = df[cols].corr(method="spearman")
    rows, cnt = [], {"consistent": 0, "opposite": 0, "no_relationship": 0}
    for a, b, sign, why in HYPOTHESES:
        if a not in sp.columns or b not in sp.columns:
            continue
        r = float(sp.loc[a, b])
        ar = abs(r)
        strength = "ninguna" if ar < 0.05 else "débil" if ar < 0.2 else "moderada" if ar < 0.5 else "fuerte"
        verdict = "no_relationship" if ar < 0.05 else ("consistent" if (r > 0) == (sign == "+") else "opposite")
        cnt[verdict] += 1
        rows.append({"a": a, "b": b, "expected_sign": sign, "spearman": r, "strength": strength, "verdict": verdict,
                     "rationale": why})
    K["hyp"] = cnt
    K["hyp_total"] = len(rows)
    return {"summary": cnt, "total": len(rows), "checks": rows,
            "interpretation": "Las relaciones circulares (p. ej. ventas-ganancia) pueden salir fuertes por construcción; "
                              "ver formulas. Muchas 'sin relación' en variables independientes sugiere generación sintética."}


def sec_leakage(df):
    r = need(df, C["late"])
    if r:
        return r
    y = df[C["late"]]
    out = {"target": C["late"], "baseline_majority_accuracy": float(max(y.mean(), 1 - y.mean()))}
    nums = [c for c in num_cols(df) if c != C["late"]] + [c for c in ("_ship_lag_days", "_gap_days", "_order_hour", "_order_dow",
                                                                       "_order_monthnum") if c in df.columns]
    aucs = []
    for c in nums:
        a = auc_binary(df[c], y)
        if a is not None:
            aucs.append({"feature": c, "auc": a, "separation": abs(a - 0.5) * 2})
    aucs.sort(key=lambda r: -r["separation"])
    out["numeric_features_auc_vs_target"] = aucs[:15]
    cats = [c for c, sp in SPEC.items() if sp["kind"] == "cat" and c in df.columns and df[c].nunique() <= 100]
    ca = []
    for c in cats:
        t = pd.crosstab(df[c], y)
        ca.append({"feature": c, "accuracy_predicting_majority_per_category": float(t.max(axis=1).sum() / t.values.sum()),
                   "n_categories": int(t.shape[0]), "role": SPEC[c]["role"]})
    ca.sort(key=lambda r: -r["accuracy_predicting_majority_per_category"])
    out["categorical_features_accuracy_vs_target"] = ca[:15]
    flagged = [r["feature"] for r in aucs if r["separation"] > 0.6] + \
              [r["feature"] for r in ca if r["accuracy_predicting_majority_per_category"] > 0.95]
    out["features_that_almost_determine_target"] = flagged
    out["candidate_leaky_columns_by_role"] = [c for c, sp in SPEC.items() if sp["role"] == "post_event" and c in df.columns]
    K["leak_flagged"] = flagged
    return out


def sec_realism(df):
    base = [c for c in (C["sched"], C["rate"], C["iprice"], C["qty"], C["real"], C["lat"], C["lon"]) if c in df.columns]
    d = df.sort_values("_order_ts") if "_order_ts" in df.columns else df
    if C["oid"] in d.columns:
        d = d.drop_duplicates(C["oid"])  # una fila por pedido: evita inflar la autocorrelación por ítems del mismo pedido
    lag1 = {c: float(d[c].autocorr(1)) for c in base if d[c].nunique() > 1}
    mean_lag = float(np.nanmean(np.abs(list(lag1.values())))) if lag1 else None
    sp = df[base].corr(method="spearman") if len(base) > 1 else None
    off = np.abs(sp.values[np.triu_indices(len(base), 1)]) if sp is not None else np.array([])
    pct_low = float(100 * np.nanmean(off < 0.05)) if off.size else None
    lag_profile, blockvr = {}, {}
    for c in base:
        if d[c].nunique() > 1:
            lag_profile[c] = {str(l): float(d[c].autocorr(l)) for l in (1, 2, 5, 10, 50, 200)}
            x = d[c].dropna().values
            nb = len(x) // 500
            if nb >= 4:  # media por bloques de 500 pedidos consecutivos vs. lo esperable si fueran independientes (~1)
                bm = x[:nb * 500].reshape(nb, 500).mean(axis=1)
                blockvr[c] = float(bm.var(ddof=1) / (x.var(ddof=1) / 500)) if x.var() > 0 else None
    uniform = {}
    if "_order_ts" in df.columns:
        o_ = df.drop_duplicates(C["oid"]) if C["oid"] in df.columns else df
        for name_, col_ in (("hour_of_day", "_order_hour"), ("weekday", "_order_dow")):
            vc = o_[col_].value_counts()
            mean_ = float(vc.mean())
            cv_ = float(vc.std(ddof=0) / mean_)
            pcv = float(1 / math.sqrt(mean_))
            uniform[name_] = {"cv_of_counts": cv_, "poisson_cv": pcv, "ratio": cv_ / pcv, "n_bins": int(len(vc)),
                              "under_dispersed": bool(cv_ / pcv < 0.5)}
    flags = {"no_temporal_autocorrelation": bool(mean_lag is not None and mean_lag < 0.05),
             "business_features_nearly_uncorrelated": bool(pct_low is not None and pct_low >= 70),
             "target_is_deterministic_function": bool(max(K.get("late_rule_match", 0), K.get("late_rule_match_excl", 0)) >= 99),
             "many_derived_or_duplicate_columns": bool(K.get("identical_groups", 0) >= 2 or K.get("formula_matches", 0) >= 3),
             "no_daily_or_weekly_pattern": bool(uniform and all(v["ratio"] < 2 for v in uniform.values()))}
    n_true = sum(flags.values())
    K["realism_flags"] = n_true
    K["uniform_under"] = bool(uniform and any(v["under_dispersed"] for v in uniform.values()))
    K["realism_total"] = len(flags)
    prof = {}
    for c in num_cols(df):
        x = df[c].dropna()
        r_ = x.max() - x.min() if len(x) else 0
        if r_ > 0 and x.nunique() > 10:
            prof[c] = ((x - x.min()) / r_).quantile(np.linspace(0.05, 0.95, 19)).values
    names = list(prof)
    parent = {c: c for c in names}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if float(np.max(np.abs(prof[a] - prof[b]))) < 0.02:
                parent[find(a)] = find(b)
    grp = {}
    for c in names:
        grp.setdefault(find(c), []).append(c)
    twins = [v for v in grp.values() if len(v) > 1]
    rank_corr = None
    if "_order_ts" in df.columns:
        rank_corr = float(df["_row_order"].corr(df["_order_ts"].rank(method="first"), method="spearman"))
    return {"lag1_autocorrelation": lag1, "mean_abs_lag1": mean_lag,
            "lag1_computed_on": "una fila por pedido (ordenado por fecha)",
            "lag_profile": lag_profile, "block500_variance_ratio": blockvr,
            "block500_note": "media por bloques de 500 pedidos consecutivos; ~1 si los valores son independientes, >>1 si hay agrupamiento temporal",
            "hour_weekday_uniformity": uniform,
            "uniformity_note": "ratio = CV de los conteos / CV esperado por azar (Poisson); ~1 = uniforme dentro del ruido; "
                               "< 0.5 = más uniforme que el azar (marcas de tiempo posiblemente sistemáticas); pedidos reales suelen tener patrón diurno/semanal",
            "pct_feature_pairs_abs_spearman_lt_0_05": pct_low,
            "file_row_order_vs_order_date_spearman": rank_corr,
            "distribution_twin_groups": twins, "flags": flags, "flags_true": n_true, "flags_total": len(flags),
            "verdict": ("alta proporción de estructura derivada/algorítmica" if n_true / len(flags) >= 0.6
                        else "señales mixtas" if n_true / len(flags) >= 0.4 else "sin indicios claros de generación sintética"),
            "warning": "Indicadores, no prueba. Columnas derivadas y objetivo determinista pueden existir en datos reales "
                       "procesados; lo relevante es no tratarlos como señal independiente."}


def _make_X(part, num, cat, cats):
    X = part[num].astype(float).copy()
    for c in cat:
        X[c] = pd.Categorical(part[c].astype(str), categories=cats[c]).codes.astype(float)
    return X


def sec_ml(df, split_date, skip):
    if skip:
        return {"skipped": "omitido por --skip-ml"}
    try:
        from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor
        from sklearn.inspection import permutation_importance
        from sklearn.metrics import accuracy_score, f1_score, mean_absolute_error, r2_score, roc_auc_score
    except Exception:
        return {"skipped": "scikit-learn no está instalado (pip install scikit-learn)"}
    r = need(df, C["late"], "_order_ts")
    if r:
        return r
    d = df.dropna(subset=["_order_ts"]).sort_values("_order_ts").copy()
    cutoff = pd.Timestamp(split_date) if split_date else d["_order_ts"].quantile(0.8)
    tr, te = d[d["_order_ts"] < cutoff], d[d["_order_ts"] >= cutoff]
    mode = f"temporal: train < {pd.Timestamp(cutoff).date()} <= test"
    if len(tr) < 500 or len(te) < 500:
        k = int(len(d) * 0.8)
        tr, te, mode = d.iloc[:k], d.iloc[k:], "temporal 80/20 (la fecha de corte dejó muy pocas filas)"
    rng = np.random.RandomState(0)
    ex_num = [c for c in (C["sched"], C["disc"], C["rate"], C["iprice"], C["qty"], C["sales"], C["total"], C["lat"], C["lon"],
                          "_order_hour", "_order_dow", "_order_monthnum") if c in d.columns]
    ex_cat = [c for c in (C["type"], C["cseg"], C["market"], C["region"], C["cat"], C["dep"], C["smode"], C["ccountry"],
                          C["ocountry"]) if c in d.columns and d[c].nunique() <= 200]
    res = {"split": mode, "train_rows": len(tr), "test_rows": len(te), "regression_target": C["profit"] if C["profit"] in d.columns else None}

    def fit_cls(num, cat, label):
        cats = {c: sorted(tr[c].astype(str).unique()) for c in cat}
        Xtr, Xte = _make_X(tr, num, cat, cats), _make_X(te, num, cat, cats)
        ytr, yte = tr[C["late"]].astype(int), te[C["late"]].astype(int)
        if ytr.nunique() < 2 or yte.nunique() < 2:
            return {"skipped": "una de las particiones tiene una sola clase"}
        m = HistGradientBoostingClassifier(max_iter=150, random_state=0).fit(Xtr, ytr)
        p = m.predict(Xte)
        prob = m.predict_proba(Xte)[:, 1]
        idx = rng.choice(len(Xte), min(len(Xte), 4000), replace=False)
        try:
            pi = permutation_importance(m, Xte.iloc[idx], yte.iloc[idx], n_repeats=3, random_state=0, scoring="roc_auc")
            imp = [{"feature": f, "importance": float(v)} for f, v in sorted(zip(Xte.columns, pi.importances_mean), key=lambda x: -x[1])[:10]]
        except Exception:  # noqa: BLE001
            imp = None
        maj = int(ytr.mode()[0])
        return {"label": label, "features": list(Xte.columns), "accuracy_test": float(accuracy_score(yte, p)),
                "roc_auc_test": float(roc_auc_score(yte, prob)), "macro_f1_test": float(f1_score(yte, p, average="macro")),
                "baseline_majority_accuracy": float((yte == maj).mean()), "top10_permutation_importance": imp}

    honest = fit_cls(ex_num, ex_cat, "honesto: solo variables conocidas al ordenar")
    leaky_num = ex_num + ([C["real"]] if C["real"] in d.columns else [])
    leaky_cat = ex_cat + ([C["dstatus"]] if C["dstatus"] in d.columns else [])
    leaky = fit_cls(leaky_num, leaky_cat, "con fuga: agrega días reales y Delivery Status")
    res["late_delivery_risk_honest"], res["late_delivery_risk_with_leakage"] = honest, leaky
    K["ml_honest"], K["ml_leaky"] = honest, leaky
    if C["profit"] in d.columns:
        rnum = [c for c in (C["sched"], C["disc"], C["rate"], C["iprice"], C["qty"], C["sales"], "_order_hour", "_order_dow",
                            "_order_monthnum") if c in d.columns]
        rcat = [c for c in (C["type"], C["cseg"], C["market"], C["region"], C["cat"], C["dep"], C["smode"]) if c in d.columns]
        cats = {c: sorted(tr[c].astype(str).unique()) for c in rcat}
        Xtr, Xte = _make_X(tr, rnum, rcat, cats), _make_X(te, rnum, rcat, cats)
        m = HistGradientBoostingRegressor(max_iter=150, random_state=0).fit(Xtr, tr[C["profit"]])
        p = m.predict(Xte)
        idx = rng.choice(len(Xte), min(len(Xte), 4000), replace=False)
        pi = permutation_importance(m, Xte.iloc[idx], te[C["profit"]].iloc[idx], n_repeats=3, random_state=0, scoring="r2")
        r2 = float(r2_score(te[C["profit"]], p))
        res["profit_regression"] = {
            "features": list(Xte.columns), "excluded": [C["pratio"], C["benefit"], "(salidas de ganancia)"],
            "r2_test": r2, "mae_test": float(mean_absolute_error(te[C["profit"]], p)),
            "mae_baseline_median": float(mean_absolute_error(te[C["profit"]], np.full(len(te), tr[C["profit"]].median()))),
            "top10_permutation_importance": [{"feature": f, "importance": float(v)} for f, v in
                                             sorted(zip(Xte.columns, pi.importances_mean), key=lambda x: -x[1])[:10]],
            "signal": "sin señal detectable (R² < 0.02)" if r2 < 0.02 else "débil" if r2 < 0.2 else "moderada" if r2 < 0.5 else "fuerte"}
        K["ml_profit_r2"] = r2
    res["note"] = "Baseline rápido (HistGradientBoosting sin tuning); la brecha honesto vs. con fuga mide cuánta información filtran las columnas post-evento."
    return res


def sec_outliers(df):
    out = {}
    if "_ship_lag_days" in df.columns:
        out["ship_before_order_rows"] = int((df["_ship_lag_days"] < 0).sum())
    if C["real"] in df.columns:
        out["real_days_over_30"] = int((df[C["real"]] > 30).sum())
    if C["rate"] in df.columns:
        out["discount_rate_over_0_5"] = int((df[C["rate"]] > 0.5).sum())
    if C["qty"] in df.columns:
        out["quantity_over_p99_9"] = int((df[C["qty"]] > df[C["qty"]].quantile(0.999)).sum())
    idcols = [c for c in (C["oid"], C["itemid"], C["cat"]) if c in df.columns]
    if C["profit"] in df.columns:
        cols = idcols + [C["sales"], C["profit"]]
        out["top5_profit"] = records(df.nlargest(5, C["profit"])[cols].round(2))
        out["bottom5_profit_largest_losses"] = records(df.nsmallest(5, C["profit"])[cols].round(2))
    if C["sales"] in df.columns:
        out["top5_sales"] = records(df.nlargest(5, C["sales"])[idcols + [C["sales"]]].round(2))
        out["items_over_p99_sales_pct_of_sales"] = float(
            100 * df.loc[df[C["sales"]] > df[C["sales"]].quantile(0.99), C["sales"]].sum() / df[C["sales"]].sum())
    if has(df, C["profit"], C["sales"]):
        out["profit_below_minus_sales_rows"] = int((df[C["profit"]] < -df[C["sales"]]).sum())
    out["iqr_outliers_by_column"] = {c: num_stats(df[c]).get("outliers_iqr") for c in num_cols(df)}
    return out


def sec_samples(df, n):
    d = df.drop(columns=[c for c in df.columns if c.startswith("_")]).copy()
    for c, sp in SPEC.items():
        if sp["kind"] == "pii" and c in d.columns:
            d[c] = "[omitido: dato personal]"
    if C["pimg"] in d.columns:
        d[C["pimg"]] = d[C["pimg"]].astype(str).str[:60]
    if C["pdesc"] in d.columns:
        d[C["pdesc"]] = d[C["pdesc"]].astype(str).str[:60]
    return {"first_rows": d.head(n).to_dict("records"), "random_rows": d.sample(min(n, len(d)), random_state=1).to_dict("records"),
            "note": "Columnas de datos personales reemplazadas por un marcador."}


def sec_access_logs(path, df):
    if not path:
        return {"skipped": "no se pasó --access-logs"}
    a, enc = read_csv_any(path)
    out = {"file": os.path.basename(path), "encoding": enc, "rows": len(a), "cols": list(a.columns), "columns": {}}
    for c in a.columns:
        s = a[c]
        low = str(c).lower()
        info = {"dtype": str(s.dtype), "nulls": int(s.isna().sum()), "nunique": int(s.nunique())}
        if low in ("ip", "ip_address") or "ip" == low.split("_")[0]:
            info["note"] = "columna tipo IP: valores omitidos"
        elif s.nunique() <= 60 or (s.dtype == object and s.nunique() <= 500):
            info["top_values"] = value_counts(s, top=15)
        elif pd.api.types.is_numeric_dtype(s):
            info["stats"] = num_stats(s)
        out["columns"][str(c)] = info
    links = {}
    pairs = {"Category": C["cat"], "Department": C["dep"], "Product": C["pname"]}
    for lc in a.columns:
        for key, mc in pairs.items():
            if norm(lc) == norm(key) and mc in df.columns:
                av = set(a[lc].dropna().astype(str).str.strip().str.lower().unique())
                mv = set(df[mc].dropna().astype(str).str.strip().str.lower().unique())
                links[f"{lc} <-> {mc}"] = {"log_unique": len(av), "main_unique": len(mv),
                                           "pct_log_values_found_in_main": 100 * len(av & mv) / max(len(av), 1),
                                           "pct_main_values_found_in_log": 100 * len(av & mv) / max(len(mv), 1)}
    out["link_with_main_dataset"] = links
    return out


def sec_description(path):
    if not path:
        return {"skipped": "no se pasó --description"}
    d, enc = read_csv_any(path)
    return {"file": os.path.basename(path), "encoding": enc, "columns": list(d.columns),
            "rows": d.head(80).fillna("").astype(str).to_dict("records")}


def sec_repro(args):
    return {"script_version": SCRIPT_VERSION, "python": platform.python_version(), "pandas": pd.__version__,
            "numpy": np.__version__, "args": vars(args),
            "parameters": {"MIN_MONTH_ITEMS": MIN_MONTH_ITEMS, "EDGE_FRAC": EDGE_FRAC, "hypotheses_count": len(HYPOTHESES)}}


def sec_findings(df):
    f, g = [], K.get
    f.append(f"{len(df):,} filas (ítems de pedido) en {g('n_orders', 0):,} pedidos"
             + (f"; {g('n_customers'):,} clientes." if g("n_customers") else "."))
    if g("late_pct") is not None:
        f.append(f"Late_delivery_risk = 1 en {g('late_pct'):.1f}% de las filas.")
    if g("late_rule_match") is not None:
        f.append(f"Late_delivery_risk coincide con 'días reales > programados' en {g('late_rule_match'):.1f}% de las filas"
                 + (f" ({g('late_rule_match_excl'):.1f}% excluyendo envíos cancelados)." if g("late_rule_match_excl") is not None else "."))
    if g("worst_mode"):
        f.append(f"Mayor tasa de atraso por modo de envío: {g('worst_mode')[0]} ({g('worst_mode')[1]:.1f}%); "
                 f"menor: {g('best_mode')[0]} ({g('best_mode')[1]:.1f}%).")
    if g("level_shifts"):
        f.append("Quiebre de nivel en la serie mensual: " + "; ".join(
            f"{k} desde {v[0]['month']} ({v[0]['pct_change']:+.0f}%)" for k, v in g("level_shifts").items()) + ".")
    if g("untrimmed_cols"):
        f.append(f"Textos con espacios sobrantes en: {', '.join(g('untrimmed_cols'))}.")
    if g("margin_pct") is not None:
        f.append(f"Ventas {g('sales_total'):,.0f}; ganancia {g('profit_total'):,.0f} (margen {g('margin_pct'):.1f}%); "
                 f"{g('loss_item_pct'):.1f}% de los ítems con pérdida.")
    if g("top_cat"):
        f.append(f"Categoría líder en ventas: {g('top_cat')[0]} ({g('top_cat')[1]:.1f}%).")
    if g("identical_groups"):
        f.append(f"{g('identical_groups')} grupos de columnas idénticas; {g('formula_matches', 0)} relaciones aritméticas "
                 f"se cumplen en >=99% de las filas.")
    if g("pii_cols"):
        f.append(f"{len(g('pii_cols'))} columnas con datos personales; aparentan estar enmascaradas: {g('pii_masked') or 'ninguna'}.")
    if g("constant_cols") or g("highnull_cols"):
        f.append(f"Columnas constantes: {g('constant_cols') or 'ninguna'}; con más de 50% de nulos: {g('highnull_cols') or 'ninguna'}.")
    if g("domain_issues"):
        f.append(f"Problemas de dominio/rango: {g('domain_issues')}.")
    if g("fraud_pct") is not None:
        f.append(f"Pedidos marcados como SUSPECTED_FRAUD: {g('fraud_pct'):.2f}% de las filas.")
    if g("leak_flagged"):
        f.append(f"Variables que casi determinan el objetivo: {', '.join(dict.fromkeys(g('leak_flagged')))}.")
    h, l = g("ml_honest"), g("ml_leaky")
    if h and "accuracy_test" in h and l and "accuracy_test" in l:
        f.append(f"Modelo base de Late_delivery_risk: honesto accuracy {h['accuracy_test']:.3f} (AUC {h['roc_auc_test']:.3f}) vs. "
                 f"con fuga {l['accuracy_test']:.3f} (AUC {l['roc_auc_test']:.3f}); mayoritaria {h['baseline_majority_accuracy']:.3f}.")
    if g("ml_profit_r2") is not None:
        f.append(f"Regresión de ganancia (features honestas): R² test {g('ml_profit_r2'):.3f}.")
    if g("hyp_total"):
        c = g("hyp")
        f.append(f"Hipótesis de dominio: {c['consistent']} consistentes, {c['opposite']} opuestas, {c['no_relationship']} sin relación (de {g('hyp_total')}).")
    if g("uniform_under"):
        f.append("Los conteos de pedidos por hora y por día de la semana son más uniformes que el azar (ratio de CV < 0.5): "
                 "sugiere marcas de tiempo generadas de forma sistemática.")
    if g("realism_flags") is not None:
        f.append(f"Indicadores de estructura derivada/sintética: {g('realism_flags')} de {g('realism_total', 4)}.")
    return f


# ----------------------------------------------------------------------------
# Contexto estático
# ----------------------------------------------------------------------------
DATASET_CONTEXT = {
    "name": "DataCo SMART SUPPLY CHAIN FOR BIG DATA ANALYSIS",
    "source": DATASET_URL, "doi": DOI, "published": "2019-03-12 (versión 5)",
    "authors": ["Fabian Constante", "Fernando Silva", "António Pereira"],
    "institutions": ["Universidad Central del Ecuador",
                     "Instituto Politécnico de Leiria (Centro de Investigação em Informática e Comunicações)"],
    "license": "No visible en la página de Mendeley consultada; verificar.",
    "summary": "Datos de cadena de suministro de la empresa DataCo Global (aprovisionamiento, producción, ventas y "
               "distribución comercial) pensados para machine learning y R; permite cruzar datos estructurados con "
               "no estructurados (clickstream).",
    "files": {"DataCoSupplyChainDataset.csv": "tabla estructurada (1 fila = 1 ítem de pedido)",
              "tokenized_access_logs.csv": "clickstream (no estructurado)",
              "DescriptionDataCoSupplyChain.csv": "diccionario de variables (usar --description para incorporarlo)"},
    "product_types": "ropa, deportes y suministros electrónicos (según la descripción)",
    "columns": {c: dict(sp) for c, sp in SPEC.items()},
    "claims_from_third_parties_to_verify": [
        "180.519 filas y 53 columnas (otro proyecto reporta 180.516 filas crudas); período 2015-2019.",
        "Se lee con codificación latin-1.",
        "Contiene datos personales (email, nombre, apellido, contraseña, calle, código postal) y URL de imagen.",
        "Product Status sería constante en 0; Product Description y Order Zipcode tendrían >75% de nulos.",
        "Order Profit Per Order, Order Item Total y Product Price serían copias exactas de otras columnas.",
        "Delivery Status y Days for shipping (real) filtran Late_delivery_risk.",
        "Algunos trabajos definen el riesgo alto como Late delivery o Shipping canceled (59,1% de las filas), distinto de Late_delivery_risk.",
        "Un proyecto reporta ~95% de entregas tardías en First Class.",
        "Hay descripciones que lo califican como simulación de una cadena global, y otras como datos reales."],
    "gotchas": [
        "Leer con encoding latin-1 si utf-8 falla.",
        "1 fila = 1 ítem de pedido: Order Id se repite; contar pedidos con nunique(Order Id).",
        "No usar ni exponer columnas de datos personales; verificar si están enmascaradas (pii_audit).",
        "Hay columnas duplicadas/derivadas: no tratarlas como señal independiente (ver structure, formulas, identical_column_groups).",
        "Late_delivery_risk puede ser función de días reales vs. programados: ver leakage antes de modelar.",
        "Para predecir atrasos usar solo variables conocidas al ordenar (p. ej. días programados, modo de envío, categoría).",
        "Ganancia negativa es legítima (pedidos con pérdida); no eliminar sin criterio.",
        "Latitude/Longitude no tienen semántica documentada: verificar antes de usar para distancias.",
        "Las fechas son texto M/D/AAAA H:MM; validar el formato al parsear.",
        "Revisar quiebres de nivel en la serie mensual (sales_profit.monthly_level_shifts) antes de comparar períodos.",
        "Hay textos con espacios sobrantes (p. ej. 'Health and Beauty '): aplicar strip antes de unir o agrupar.",
        "Usar validación con corte temporal, no aleatoria.",
        "Comparar nº de filas/columnas contra lo reportado por terceros; puede haber versiones distintas del archivo."],
    "definitions": {
        "item": "fila de la tabla (Order Item Id)", "order": "Order Id (agrupa ítems)",
        "late_delivery_risk": "variable objetivo binaria; ver formulas/leakage para su relación con días reales vs. programados",
        "gap_days": "días reales - días programados", "ship_lag_days": "fecha de envío - fecha de pedido (días)",
        "margin_pct": "100 x ganancia / ventas", "loss_item": "ítem con Order Profit Per Order < 0",
        "honest_features": "variables conocidas al momento de ordenar (sin días reales ni Delivery Status)"},
}
ANALYSIS_INDEX = {
    "metadata": "tamaño, codificación, rango de fechas, metodología", "dataset_context": "descripción, columnas, trampas",
    "reproducibility": "versiones y parámetros", "description_file": "diccionario oficial si se pasó --description",
    "samples": "filas de ejemplo sin datos personales", "data_quality": "perfil por columna, duplicados, columnas idénticas",
    "pii_audit": "auditoría de datos personales sin imprimir valores", "structure": "granularidad, consistencia intra-pedido, mapeos 1:1",
    "declared_vs_observed": "dominios y rangos esperados vs. observados", "formulas": "relaciones aritméticas entre columnas",
    "delivery": "atrasos por modo, mercado, región, categoría, tipo de pago", "sales_profit": "ventas, ganancia, descuentos, mensual, concentración",
    "geography": "mercados, regiones, países y coordenadas", "customers": "recompra, gasto, cohortes",
    "products": "catálogo, precios, categorías", "orders_status": "estados de pedido y entrega, fraude sospechado",
    "temporal": "cobertura diaria, estacionalidad, demora de envío", "correlations": "matrices, pares, features vs. objetivos",
    "hypothesis_checks": "relaciones esperadas de dominio", "leakage": "variables que determinan el objetivo",
    "realism_indicators": "pistas de estructura derivada o sintética", "ml_baseline": "honesto vs. con fuga; regresión de ganancia",
    "outliers": "valores extremos", "access_logs": "perfil del clickstream (si se pasó)", "key_findings": "resumen en frases"}


# ----------------------------------------------------------------------------
# Contexto compacto
# ----------------------------------------------------------------------------
def tbl(rows, drop=()):
    """Tabla compacta: {"columns": [...], "rows": [[...]]} (evita repetir las claves en cada fila)."""
    rows = [r for r in (rows or []) if isinstance(r, dict)]
    if not rows:
        return None
    cols = [c for c in rows[0].keys() if c not in drop]
    return {"columns": cols, "rows": [[r.get(c) for c in cols] for r in rows]}


def write_context(path, ctx):
    """Una línea compacta por sección: legible por secciones y eficiente en tokens."""
    c = clean(ctx, nd=3)
    parts = [f"{json.dumps(k, ensure_ascii=False)}:{json.dumps(v, ensure_ascii=False, separators=(',', ':'))}"
             for k, v in c.items()]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("{\n" + ",\n".join(parts) + "\n}\n")


def build_context(out):
    g = lambda *p: dig(out, *p)  # noqa: E731
    gb = g("delivery", "by_group") or {}
    sp = g("sales_profit", "by_group") or {}
    cols = g("data_quality", "columns") or {}
    desc = g("description_file")
    has_desc = isinstance(desc, dict) and "rows" in desc
    dc_compact = dict(g("dataset_context") or {})
    dc_compact["columns"] = {c: (f"[{sp['kind']}/{sp['role']}]" if has_desc else f"{sp['description']} [{sp['kind']}/{sp['role']}]")
                             for c, sp in (dc_compact.get("columns") or {}).items()}
    ctx = {
        "purpose": "Contexto compacto del dataset DataCo Smart Supply Chain para conversaciones futuras. Para el detalle "
                   "(perfil por columna, tablas completas), pedir el JSON completo.",
        "usage_instructions": [
            "Responder con las cifras de este archivo; si falta una, decir que hace falta el JSON completo o el CSV.",
            "No pedir ni mostrar datos personales; las columnas con PII están solo auditadas.",
            "Distinguir lo esperado (documentación de terceros) de lo observado (datos).",
            "Al hablar de predicción de atrasos, separar variables conocidas al ordenar de las que filtran el resultado."],
        "metadata": g("metadata"), "dataset_context": dc_compact,
        "official_description_file": desc if isinstance(desc, dict) and "rows" in desc else None,
        "key_findings": g("key_findings"),
        "data_quality_highlights": {
            "duplicate_rows": g("data_quality", "duplicate_rows"),
            "constant_columns": g("data_quality", "constant_columns"),
            "columns_over_50pct_null": g("data_quality", "columns_over_50pct_null"),
            "columns_with_untrimmed_text": g("data_quality", "columns_with_untrimmed_text"),
            "identical_column_groups": g("data_quality", "identical_column_groups"),
            "nulls_nonzero": {c: i.get("null_pct") for c, i in cols.items() if i.get("nulls")},
            "pii_columns_masked": g("pii_audit", "columns_that_look_masked"),
            "pii_columns": list((g("pii_audit", "columns") or {}).keys()),
            "domain_issues": g("declared_vs_observed", "issues"),
            "structure": {k: g("structure", k) for k in ("orders", "items_per_order", "orders_with_multiple_items_pct",
                                                         "order_item_id_is_unique", "within_order_inconsistency_pct",
                                                         "column_mappings")},
            "formulas_pct_match": {k: v.get("pct_match") for k, v in (g("formulas", "checks") or {}).items()}},
        "key_metrics": {
            "volume": {"rows": g("metadata", "rows"), "orders": g("structure", "orders"), "customers": g("customers", "customers"),
                       "products": g("products", "n_products"), "categories": g("products", "n_categories"),
                       "order_date_range": g("metadata", "order_date_range"),
                       "ship_date_range": g("temporal", "ship_date_range"),
                       "days_without_orders_pct": g("temporal", "days_without_orders_pct")},
            "delivery": {"late_delivery_risk_pct": g("delivery", "late_delivery_risk_pct"),
                         "days_real": {k: g("delivery", "days_real_stats", k) for k in ("mean", "median", "min", "max")},
                         "days_scheduled": {k: g("delivery", "days_scheduled_stats", k) for k in ("mean", "median", "min", "max")},
                         "late_pct_by_gap_days": g("delivery", "late_pct_by_gap_days"),
                         "real_days_by_shipping_mode": {k: {st: v.get(st) for st in ("mean", "min", "p25", "median", "p75", "max")}
                                                        for k, v in (g("delivery", "real_days_by_shipping_mode") or {}).items()},
                         "late_risk_pct_by_delivery_status": g("delivery", "late_risk_pct_by_delivery_status"),
                         "delivery_status_distribution": g("delivery", "delivery_status_distribution"),
                         "by_shipping_mode": tbl(gb.get("Shipping Mode")), "by_market": tbl(gb.get("Market")),
                         "by_region": tbl(gb.get("Order Region"), drop=("avg_gap_days",)),
                         "by_segment": tbl(gb.get("Customer Segment")), "by_department": tbl(gb.get("Department Name")),
                         "by_payment_type": tbl(gb.get("Type")),
                         "by_category_top8": tbl((gb.get("Category Name") or [])[:8], drop=("avg_gap_days",)),
                         "by_shipping_mode_and_scheduled_days": tbl(g("delivery", "by_shipping_mode_and_scheduled_days")),
                         "late_pct_by_order_month_columns": ["month", "late_pct"],
                         "late_pct_by_order_month": [[m, v.get("late_pct")] for m, v in
                                                     (g("delivery", "late_pct_by_order_month") or {}).items()]},
            "leakage": {"late_rule_match_pct": g("formulas", "checks", "Late_delivery_risk = (días reales > programados)"),
                        "late_rule_exceptions": g("formulas", "late_rule_exceptions"),
                        "features_that_almost_determine_target": g("leakage", "features_that_almost_determine_target"),
                        "numeric_auc_top5": (g("leakage", "numeric_features_auc_vs_target") or [])[:5],
                        "categorical_accuracy_top5": (g("leakage", "categorical_features_accuracy_vs_target") or [])[:5]},
            "sales_profit": {k: g("sales_profit", k) for k in ("sales_total", "profit_total", "margin_pct",
                                                               "loss_making_items_pct", "loss_total", "loss_making_orders_pct",
                                                               "discount_rate_vs_profit_spearman", "by_discount_rate_bin",
                                                               "category_sales_concentration", "product_sales_concentration",
                                                               "top5_categories_by_profit", "bottom5_categories_by_profit",
                                                               "median_monthly_sales_growth_pct", "monthly_level_shifts", "months_with_partial_coverage",
                                                               "calendar_months_missing_in_range", "yearly")},
            "profit_by_group": {"category": tbl(sp.get("Category Name"), drop=("avg_discount_rate",)),
                                "department": tbl(sp.get("Department Name")), "market": tbl(sp.get("Market")),
                                "region": tbl(sp.get("Order Region"), drop=("avg_discount_rate",)),
                                "shipping_mode": tbl(sp.get("Shipping Mode")), "segment": tbl(sp.get("Customer Segment")),
                                "payment_type": tbl(sp.get("Type"))},
            "monthly_columns": ["month", "items", "orders", "sales", "profit", "margin_pct", "late_pct", "partial_coverage",
                                "items_per_order"],
            "monthly": [[m.get("month"), m.get("items"), m.get("orders"), m.get("sales"), m.get("profit"), m.get("margin_pct"),
                         m.get("late_pct"), m.get("partial_coverage"), m.get("items_per_order")]
                        for m in (g("sales_profit", "monthly") or [])],
            "customers": {**{k: g("customers", k) for k in ("repeat_customers_pct", "customers_by_segment",
                                                            "customers_with_multiple_segments_pct", "avg_spend_by_segment",
                                                            "orders_per_customer_distribution")},
                          "repeat_pct_by_first_order_quarter": tbl(g("customers", "repeat_pct_by_first_order_quarter"))},
            "outliers": {k: g("outliers", k) for k in ("profit_below_minus_sales_rows", "bottom5_profit_largest_losses",
                                                       "items_over_p99_sales_pct_of_sales")},
            "customer_spend_concentration": g("customers", "spend_concentration"),
            "products": {k: g("products", k) for k in ("products_with_multiple_prices_pct", "categories_per_department")},
            "orders_status": {**{k: g("orders_status", k) for k in ("Order Status distribution", "Type distribution",
                                                                   "suspected_fraud_pct", "canceled_pct",
                                                                   "late_risk_pct_among_canceled")},
                              "order_status_within_delivery_status_shipping_canceled":
                                  (g("orders_status", "delivery_status_vs_order_status_counts") or {}).get("Shipping canceled")},
            "geography": {**{k: g("geography", k) for k in ("sales_share_by_market_pct",
                                                            "customer_country_differs_from_order_country_pct",
                                                            "unique_coordinate_pairs", "pct_lon_positive",
                                                            "Customer Country (top 20)", "Order Country n_unique")},
                          "lat_mean_min_max": [g("geography", "lat_stats", k) for k in ("mean", "min", "max")],
                          "lon_mean_min_max": [g("geography", "lon_stats", k) for k in ("mean", "min", "max")]},
            "temporal": {k: g("temporal", k) for k in ("ship_lag_days_stats", "ship_before_order_pct",
                                                       "daily_dispersion_index_var_over_mean", "trend_spearman_vs_time")},
            "correlations": {"top_pairs": pick((g("correlations", "top25_pairs_by_abs_spearman") or [])[:8], ["a", "b", "spearman"]),
                             "near_duplicate_pairs": pick(g("correlations", "near_duplicate_pairs_abs_spearman_gt_0_995"),
                                                          ["a", "b", "spearman"]),
                             "top_features_late_risk": pick((g("correlations", "features_vs_targets", "Late_delivery_risk") or [])[:6],
                                                            ["feature", "spearman", "auc_vs_target", "possible_leak"]),
                             "top_features_profit": pick((g("correlations", "features_vs_targets", "Order Profit Per Order") or [])[:6],
                                                         ["feature", "spearman", "possible_leak"])},
            "hypotheses": {"summary": g("hypothesis_checks", "summary"),
                           "not_consistent": pick([h for h in (g("hypothesis_checks", "checks") or []) if h["verdict"] != "consistent"],
                                                  ["a", "b", "expected_sign", "spearman", "verdict"])},
            "realism": {k: g("realism_indicators", k) for k in ("flags", "flags_true", "verdict", "mean_abs_lag1",
                                                                 "distribution_twin_groups",
                                                                 "file_row_order_vs_order_date_spearman", "lag_profile",
                                                                 "block500_variance_ratio", "hour_weekday_uniformity")},
            "ml_baseline": {"split": g("ml_baseline", "split") or g("ml_baseline", "skipped"),
                            "late_risk_honest": {k: g("ml_baseline", "late_delivery_risk_honest", k) for k in
                                                 ("accuracy_test", "roc_auc_test", "macro_f1_test", "baseline_majority_accuracy")},
                            "late_risk_with_leakage": {k: g("ml_baseline", "late_delivery_risk_with_leakage", k) for k in
                                                       ("accuracy_test", "roc_auc_test", "macro_f1_test")},
                            "honest_top_features": [x["feature"] for x in (g("ml_baseline", "late_delivery_risk_honest",
                                                                             "top10_permutation_importance") or [])[:5]],
                            "profit_regression": {k: g("ml_baseline", "profit_regression", k) for k in
                                                  ("r2_test", "mae_test", "mae_baseline_median", "signal")}},
            "access_logs": g("access_logs") if isinstance(g("access_logs"), dict) and "rows" in (g("access_logs") or {}) else None},
        "samples_2_rows": (g("samples", "first_rows") or [])[:2],
        "analysis_index": ANALYSIS_INDEX}
    return ctx


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Contexto y análisis en JSON: DataCo Smart Supply Chain")
    ap.add_argument("--csv", required=True, help="DataCoSupplyChainDataset.csv o la carpeta que lo contiene")
    ap.add_argument("--output", default="dataco_analysis.json")
    ap.add_argument("--context-output", default=None, help="Por defecto: <output>_context.json")
    ap.add_argument("--description", default=None, help="DescriptionDataCoSupplyChain.csv (opcional)")
    ap.add_argument("--access-logs", default=None, help="tokenized_access_logs.csv (opcional)")
    ap.add_argument("--split-date", default=None, help="Corte temporal del modelo base (por defecto percentil 80)")
    ap.add_argument("--skip-ml", action="store_true")
    ap.add_argument("--sample-rows", type=int, default=5)
    args = ap.parse_args()
    ctx_path = args.context_output or re.sub(r"\.json$", "", args.output) + "_context.json"

    path = find_csv(args.csv)
    df, notes, enc = load(path)
    out = {}
    safe("metadata", lambda: sec_metadata(df, path, notes, enc), out)
    safe("dataset_context", lambda: DATASET_CONTEXT, out)
    safe("reproducibility", lambda: sec_repro(args), out)
    safe("description_file", lambda: sec_description(args.description), out)
    safe("samples", lambda: sec_samples(df, args.sample_rows), out)
    safe("data_quality", lambda: sec_quality(df), out)
    safe("pii_audit", lambda: sec_pii(df), out)
    safe("structure", lambda: sec_structure(df), out)
    safe("declared_vs_observed", lambda: sec_declared_vs_observed(df), out)
    safe("formulas", lambda: sec_formulas(df), out)
    safe("delivery", lambda: sec_delivery(df), out)
    safe("sales_profit", lambda: sec_sales_profit(df), out)
    safe("geography", lambda: sec_geography(df), out)
    safe("customers", lambda: sec_customers(df), out)
    safe("products", lambda: sec_products(df), out)
    safe("orders_status", lambda: sec_orders_status(df), out)
    safe("temporal", lambda: sec_temporal(df), out)
    safe("correlations", lambda: sec_correlations(df), out)
    safe("hypothesis_checks", lambda: sec_hypotheses(df), out)
    safe("leakage", lambda: sec_leakage(df), out)
    safe("realism_indicators", lambda: sec_realism(df), out)
    safe("ml_baseline", lambda: sec_ml(df, args.split_date, args.skip_ml), out)
    safe("outliers", lambda: sec_outliers(df), out)
    safe("access_logs", lambda: sec_access_logs(args.access_logs, df), out)
    out["key_findings"] = sec_findings(df)

    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(clean(out), fh, ensure_ascii=False, indent=2)
    write_context(ctx_path, build_context(out))
    errors = [k for k, v in out.items() if isinstance(v, dict) and "error" in v]
    print(f"OK completo  -> {args.output} ({os.path.getsize(args.output) / 1e3:.0f} KB)")
    print(f"OK contexto  -> {ctx_path} ({os.path.getsize(ctx_path) / 1e3:.0f} KB)")
    print(f"Secciones con error: {errors or 'ninguna'}")


if __name__ == "__main__":
    main()
