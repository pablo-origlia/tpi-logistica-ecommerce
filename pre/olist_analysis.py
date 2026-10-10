#!/usr/bin/env python3
"""
Análisis exhaustivo del dataset Brazilian E-Commerce (Olist) -> JSON completo + JSON de contexto compacto (v2.1)

Uso:
    python olist_analysis.py --data-dir ./olist_csv --output olist_analysis.json
    (genera también olist_analysis_context.json, el archivo compacto para pegar como contexto)

En un notebook de Kaggle:
    python olist_analysis.py --data-dir /kaggle/input/brazilian-ecommerce --output /kaggle/working/olist_analysis.json

Requisitos: pandas, numpy  (pip install pandas numpy)

Criterios metodológicos (también quedan registrados en el JSON):
  - "Pedidos válidos" = todos excepto status 'canceled' y 'unavailable'.
  - Ingresos (GMV) = suma de price de order_items (sin flete), salvo que se indique.
  - Métricas de entrega solo sobre pedidos 'delivered' con fecha real de entrega.
  - Para reviews se usa la más reciente por pedido (hay pedidos con varias).
  - Clientes únicos = customer_unique_id (customer_id cambia en cada pedido).
"""
import argparse
import json
import math
import os
import re
import sys
import platform
import traceback
from collections import Counter
from itertools import combinations
from datetime import datetime

import numpy as np
import pandas as pd

FILES = {
    "orders": "olist_orders_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "customers": "olist_customers_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "products": "olist_products_dataset.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "translation": "product_category_name_translation.csv",
}

DATE_COLS = {
    "orders": ["order_purchase_timestamp", "order_approved_at", "order_delivered_carrier_date",
               "order_delivered_customer_date", "order_estimated_delivery_date"],
    "order_items": ["shipping_limit_date"],
    "order_reviews": ["review_creation_date", "review_answer_timestamp"],
}

PT_STOPWORDS = set("""
a o as os um uma uns umas de do da dos das em no na nos nas por para com sem sob sobre e ou mas que se
como mais muito muita muitos muitas ja foi ser ter tem tinha era eu me meu minha meus minhas nao não sim
ao aos à às pelo pela pelos pelas este esta isso isto esse essa aquele aquela ate até so só tudo todo toda
bem mal foi vem veio produto produtos pedido compra comprei recebi recebido chegou entrega entregue prazo
loja lojas ainda porem porém quando onde ele ela eles elas seu sua nem tambem também la lá aqui há
estou agora pois apenas mesmo está estão são vez fazer feito fiz faz pra pro tive tenho fui sendo ficou apos após
depois antes dentro mim cada outro outra outros outras qual quais quem entre durante né ok tão tanto quero dois
""".split())

K = {}  # KPIs globales para los hallazgos automáticos
SCRIPT_VERSION = "2.1"
MIN_MONTH_ORDERS = 100  # meses con menos pedidos se marcan como cobertura parcial
BBOX = (-34.0, 6.0, -74.0, -34.0)  # lat_min, lat_max, lng_min, lng_max de Brasil
DIST_BINS = [-0.1, 50, 200, 500, 1000, 2000, 3000, np.inf]
DIST_LABELS = ["<50", "50-200", "200-500", "500-1000", "1000-2000", "2000-3000", ">3000"]
GOT_HOUSES = {"stark", "lannister", "targaryen", "baratheon", "greyjoy", "tyrell", "martell", "arryn", "tully",
              "tarly", "bolton", "frey", "mormont", "umber"}  # ruido de anonimización
NGRAM_EDGE_STOP = set("a o as os um uma uns umas de do da dos das em no na nos nas por para com e ou que se ao aos à às pelo pela pelos pelas é foi".split())



# ----------------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------------
def clean(o, nd=4):
    """Convierte cualquier estructura a tipos serializables por JSON."""
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
    return {
        "count": int(s.size), "mean": s.mean(), "std": s.std(), "min": s.min(),
        "p1": q.loc[0.01], "p5": q.loc[0.05], "p25": q.loc[0.25], "median": q.loc[0.5],
        "p75": q.loc[0.75], "p95": q.loc[0.95], "p99": q.loc[0.99], "max": s.max(),
        "skew": s.skew(), "outliers_iqr": int(((s < lo) | (s > hi)).sum()),
    }


def value_counts(s, top=None, normalize_pct=True):
    vc = s.value_counts(dropna=False)
    if top:
        vc = vc.head(top)
    total = len(s)
    return {str(k): {"n": int(v), "pct": round(100 * v / total, 2) if normalize_pct else None}
            for k, v in vc.items()}


def records(df):
    return df.reset_index().to_dict("records") if df.index.name or isinstance(df.index, pd.MultiIndex) \
        else df.to_dict("records")


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
    tot = v.sum()
    if tot == 0 or v.size == 0:
        return {}
    shares = v / tot
    n = v.size
    return {
        "n_entities": int(n),
        "top1_share_pct": 100 * shares[:1].sum(),
        "top10_share_pct": 100 * shares[:10].sum(),
        "top_1pct_entities_share_pct": 100 * shares[:max(1, n // 100)].sum(),
        "top_10pct_entities_share_pct": 100 * shares[:max(1, n // 10)].sum(),
        "top_20pct_entities_share_pct": 100 * shares[:max(1, n // 5)].sum(),
        "entities_for_80pct_revenue": int(np.searchsorted(np.cumsum(shares), 0.8) + 1),
        "hhi": float((shares ** 2).sum() * 10000),
        "gini": gini(v),
    }


def safe(name, fn, out):
    try:
        out[name] = fn()
    except Exception as e:  # una sección rota no debe tumbar el resto
        out[name] = {"error": f"{type(e).__name__}: {e}", "trace": traceback.format_exc(limit=3)}
        print(f"[WARN] sección '{name}' falló: {e}", file=sys.stderr)


# ----------------------------------------------------------------------------
# Carga
# ----------------------------------------------------------------------------
def load(data_dir, geo_sample=None):
    D, notes = {}, []
    for key, fname in FILES.items():
        path = os.path.join(data_dir, fname)
        if not os.path.exists(path):
            notes.append(f"Archivo faltante: {fname}")
            continue
        df = pd.read_csv(path, parse_dates=DATE_COLS.get(key, []))
        if key == "geolocation" and geo_sample and len(df) > geo_sample:
            notes.append(f"geolocation muestreada: {geo_sample} de {len(df)} filas")
            df = df.sample(geo_sample, random_state=42)
        D[key] = df
    return D, notes


# ----------------------------------------------------------------------------
# Construcción de tablas derivadas
# ----------------------------------------------------------------------------
def build(D):
    o, items, pay, rev = D["orders"], D["order_items"], D["order_payments"], D["order_reviews"]
    cust, prod = D["customers"], D["products"]

    # review más reciente por pedido
    rv = (rev.sort_values("review_answer_timestamp")
             .drop_duplicates("order_id", keep="last")
             .loc[:, ["order_id", "review_score", "review_comment_title", "review_comment_message",
                      "review_creation_date", "review_answer_timestamp"]])

    oi = items.groupby("order_id").agg(
        n_items=("order_item_id", "count"), items_value=("price", "sum"),
        freight_value=("freight_value", "sum"), n_sellers=("seller_id", "nunique"),
        n_products=("product_id", "nunique"))
    op = pay.groupby("order_id").agg(
        payment_value=("payment_value", "sum"), n_payment_types=("payment_type", "nunique"),
        max_installments=("payment_installments", "max"))

    od = (o.merge(cust, on="customer_id", how="left")
            .merge(oi, on="order_id", how="left")
            .merge(op, on="order_id", how="left")
            .merge(rv, on="order_id", how="left"))
    od["purchase_month"] = od["order_purchase_timestamp"].dt.to_period("M").astype(str)
    od["valid"] = ~od["order_status"].isin(["canceled", "unavailable"])

    # delivery
    day = 86400.0
    od["delivery_days"] = (od.order_delivered_customer_date - od.order_purchase_timestamp).dt.total_seconds() / day
    od["estimated_days"] = (od.order_estimated_delivery_date - od.order_purchase_timestamp).dt.total_seconds() / day
    od["delay_days"] = (od.order_delivered_customer_date - od.order_estimated_delivery_date).dt.total_seconds() / day
    od["approval_hours"] = (od.order_approved_at - od.order_purchase_timestamp).dt.total_seconds() / 3600
    od["to_carrier_days"] = (od.order_delivered_carrier_date - od.order_purchase_timestamp).dt.total_seconds() / day
    od["last_mile_days"] = (od.order_delivered_customer_date - od.order_delivered_carrier_date).dt.total_seconds() / day
    od["is_late"] = od["delay_days"] > 0

    # nivel ítem
    trans = D.get("translation")
    p = prod.copy()
    if trans is not None:
        p = p.merge(trans, on="product_category_name", how="left")
        p["category"] = p["product_category_name_english"].fillna(p["product_category_name"])
    else:
        p["category"] = p["product_category_name"]
    p["category"] = p["category"].fillna("unknown")

    pcols = [c for c in ["product_id", "category", "product_weight_g", "product_length_cm", "product_height_cm",
                         "product_width_cm"] if c in p.columns]
    it = (items.merge(od[["order_id", "order_status", "valid", "purchase_month", "customer_state",
                          "customer_unique_id", "customer_zip_code_prefix", "review_score", "is_late",
                          "delivery_days", "delay_days", "order_purchase_timestamp",
                          "order_delivered_carrier_date"]],
                      on="order_id", how="left")
               .merge(p[pcols], on="product_id", how="left")
               .merge(D["sellers"][["seller_id", "seller_state", "seller_city", "seller_zip_code_prefix"]],
                      on="seller_id", how="left"))
    it["category"] = it["category"].fillna("unknown")
    it["volume_cm3"] = it.get("product_length_cm") * it.get("product_height_cm") * it.get("product_width_cm")
    return od, it, p, rv


# ----------------------------------------------------------------------------
# Secciones
# ----------------------------------------------------------------------------
def sec_metadata(D, notes):
    return {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "tables_loaded": {k: {"rows": len(v), "cols": len(v.columns)} for k, v in D.items()},
        "notes": notes,
        "methodology": {
            "valid_orders": "status distinto de canceled/unavailable",
            "revenue": "suma de order_items.price (sin flete)",
            "delivery_metrics": "solo pedidos delivered con fecha real de entrega",
            "reviews": "review más reciente por pedido",
            "unique_customer": "customer_unique_id",
            "caveats": ["Los meses de 2016 y fines de 2018 tienen muy pocos pedidos (cobertura parcial).",
                        "Los textos de reviews están en portugués; las categorías se traducen con la tabla de traducción."],
        },
    }


def sec_data_quality(D):
    res = {}
    for name, df in D.items():
        cols = {}
        for c in df.columns:
            s = df[c]
            info = {"dtype": str(s.dtype), "nulls": int(s.isna().sum()),
                    "null_pct": round(100 * s.isna().mean(), 3), "nunique": int(s.nunique(dropna=True))}
            if pd.api.types.is_numeric_dtype(s) and not pd.api.types.is_bool_dtype(s):
                info["stats"] = num_stats(s)
            elif pd.api.types.is_datetime64_any_dtype(s):
                info["min"], info["max"] = s.min(), s.max()
            elif info["nunique"] <= 40:
                info["top_values"] = value_counts(s, top=15)
            cols[c] = info
        res[name] = {
            "rows": len(df), "cols": len(df.columns),
            "memory_mb": round(df.memory_usage(deep=True).sum() / 1e6, 2),
            "duplicate_rows": int(df.duplicated().sum()),
            "columns": cols,
        }
    # claves
    keys = {
        "orders.order_id": ("orders", ["order_id"]),
        "customers.customer_id": ("customers", ["customer_id"]),
        "products.product_id": ("products", ["product_id"]),
        "sellers.seller_id": ("sellers", ["seller_id"]),
        "order_items.(order_id,order_item_id)": ("order_items", ["order_id", "order_item_id"]),
        "order_payments.(order_id,payment_sequential)": ("order_payments", ["order_id", "payment_sequential"]),
        "order_reviews.review_id": ("order_reviews", ["review_id"]),
        "order_reviews.(review_id,order_id)": ("order_reviews", ["review_id", "order_id"]),
    }
    res["_primary_key_checks"] = {
        label: {"duplicated_keys": int(D[t].duplicated(subset=cols).sum())}
        for label, (t, cols) in keys.items() if t in D
    }
    return res


def sec_integrity(D):
    def orphan(ct, ck, pt, pk):
        if ct not in D or pt not in D:
            return None
        child = D[ct][ck].dropna()
        missing = ~child.isin(set(D[pt][pk]))
        return {"child_rows_checked": int(len(child)), "orphans": int(missing.sum()),
                "orphan_pct": round(100 * missing.mean(), 4)}

    def coverage(pt, pk, ct, ck):
        if ct not in D or pt not in D:
            return None
        pset = D[pt][pk].dropna().unique()
        miss = ~pd.Series(pset).isin(set(D[ct][ck]))
        return {"parents": int(len(pset)), "without_children": int(miss.sum()),
                "pct": round(100 * miss.mean(), 3)}

    return {
        "orphans": {
            "order_items.order_id -> orders": orphan("order_items", "order_id", "orders", "order_id"),
            "order_items.product_id -> products": orphan("order_items", "product_id", "products", "product_id"),
            "order_items.seller_id -> sellers": orphan("order_items", "seller_id", "sellers", "seller_id"),
            "order_payments.order_id -> orders": orphan("order_payments", "order_id", "orders", "order_id"),
            "order_reviews.order_id -> orders": orphan("order_reviews", "order_id", "orders", "order_id"),
            "orders.customer_id -> customers": orphan("orders", "customer_id", "customers", "customer_id"),
            "products.category -> translation": orphan("products", "product_category_name", "translation",
                                                       "product_category_name"),
        },
        "parents_without_children": {
            "orders sin items": coverage("orders", "order_id", "order_items", "order_id"),
            "orders sin pagos": coverage("orders", "order_id", "order_payments", "order_id"),
            "orders sin review": coverage("orders", "order_id", "order_reviews", "order_id"),
            "products sin ventas": coverage("products", "product_id", "order_items", "product_id"),
            "sellers sin ventas": coverage("sellers", "seller_id", "order_items", "seller_id"),
        },
    }


def sec_orders(od):
    ts = od["order_purchase_timestamp"]
    v = od[od.valid]
    K["n_orders"] = len(od)
    K["n_valid_orders"] = len(v)
    dow = ts.dt.day_name().value_counts()
    hour = ts.dt.hour.value_counts().sort_index()
    return {
        "total_orders": len(od),
        "valid_orders": len(v),
        "date_range": {"first_purchase": ts.min(), "last_purchase": ts.max()},
        "status_distribution": value_counts(od["order_status"]),
        "items_per_order": {"distribution": value_counts(od["n_items"].fillna(0).astype(int), top=10),
                            "stats": num_stats(od["n_items"])},
        "multi_seller_orders_pct": round(100 * (od["n_sellers"] > 1).sum() / od["n_sellers"].notna().sum(), 3),
        "orders_by_weekday": {k: int(x) for k, x in dow.items()},
        "orders_by_hour": {int(k): int(x) for k, x in hour.items()},
        "orders_by_month": od.groupby("purchase_month").size().to_dict(),
        "approval_time_hours": num_stats(od["approval_hours"]),
        "temporal_anomalies": {
            "approved_before_purchase": int((od.order_approved_at < od.order_purchase_timestamp).sum()),
            "carrier_before_purchase": int((od.order_delivered_carrier_date < od.order_purchase_timestamp).sum()),
            "delivered_before_carrier": int((od.order_delivered_customer_date < od.order_delivered_carrier_date).sum()),
            "delivered_before_purchase": int((od.order_delivered_customer_date < od.order_purchase_timestamp).sum()),
            "delivered_status_without_delivery_date": int(((od.order_status == "delivered") &
                                                           od.order_delivered_customer_date.isna()).sum()),
            "non_delivered_with_delivery_date": int(((od.order_status != "delivered") &
                                                     od.order_delivered_customer_date.notna()).sum()),
        },
    }


def sec_sales(od, it):
    v = it[it.valid == True]  # noqa: E712
    K["gmv"] = float(v.price.sum())
    K["freight_total"] = float(v.freight_value.sum())
    vo = od[od.valid & od.items_value.notna()]
    m = (od[od.valid].groupby("purchase_month")
         .agg(orders=("order_id", "count"), unique_customers=("customer_unique_id", "nunique"),
              revenue=("items_value", "sum"), freight=("freight_value", "sum"),
              avg_ticket=("items_value", "mean"), avg_review=("review_score", "mean"),
              late_pct=("is_late", "mean")))
    m["late_pct"] *= 100
    # MoM solo entre meses calendario consecutivos y con volumen mínimo en ambos (evita explosiones por meses vacíos)
    idx = pd.period_range(pd.Period(m.index.min()), pd.Period(m.index.max()), freq="M").astype(str)
    mm = m.reindex(idx)
    ok = (mm.orders >= MIN_MONTH_ORDERS) & (mm.orders.shift(1) >= MIN_MONTH_ORDERS)
    m["revenue_mom_pct"] = ((mm.revenue / mm.revenue.shift(1) - 1) * 100).where(ok).reindex(m.index)
    m["orders_mom_pct"] = ((mm.orders / mm.orders.shift(1) - 1) * 100).where(ok).reindex(m.index)
    m["partial_coverage"] = m.orders < MIN_MONTH_ORDERS
    full = m[~m.partial_coverage]
    yoy = {}
    for y in sorted({i[:4] for i in m.index}):
        sub = m[m.index.str.startswith(y)]
        yoy[y] = {"orders": int(sub.orders.sum()), "revenue": sub.revenue.sum(), "months_with_data": int(len(sub))}
    freight_ratio = (v.freight_value / v.price.replace(0, np.nan))
    return {
        "gmv_items_total": v.price.sum(),
        "freight_total": v.freight_value.sum(),
        "freight_pct_of_gmv": 100 * v.freight_value.sum() / v.price.sum(),
        "items_sold": len(v),
        "avg_item_price": v.price.mean(),
        "item_price_stats": num_stats(v.price),
        "freight_stats": num_stats(v.freight_value),
        "freight_to_price_ratio_stats": num_stats(freight_ratio),
        "order_value_stats": num_stats(vo.items_value),
        "order_value_with_freight_stats": num_stats(vo.items_value + vo.freight_value),
        "monthly": records(m.round(3)),
        "yearly": yoy,
        "best_month_by_revenue": full["revenue"].idxmax() if len(full) else None,
        "avg_monthly_growth_pct_full_months": m["revenue_mom_pct"].mean(),
        "median_monthly_growth_pct_full_months": m["revenue_mom_pct"].median(),
        "months_with_partial_coverage": m.index[m.partial_coverage].tolist(),
        "calendar_months_missing_in_range": [i for i in idx if i not in m.index],
        "growth_note": f"MoM solo entre meses consecutivos con >= {MIN_MONTH_ORDERS} pedidos en ambos.",
        "revenue_by_weekday": v.assign(d=od.set_index("order_id").loc[v.order_id, "order_purchase_timestamp"]
                                       .dt.day_name().values).groupby("d").price.sum().to_dict(),
    }


def sec_delivery(od):
    dl = od[(od.order_status == "delivered") & od.order_delivered_customer_date.notna()].copy()
    K["late_pct"] = float(100 * dl.is_late.mean())
    K["avg_delivery_days"] = float(dl.delivery_days.mean())
    dl["delay_bucket"] = pd.cut(dl.delay_days, [-np.inf, 0, 3, 7, 14, np.inf],
                                labels=["a_tiempo_o_antes", "1-3d_tarde", "4-7d_tarde", "8-14d_tarde", ">14d_tarde"])
    bucket = (dl.groupby("delay_bucket", observed=False)
              .agg(orders=("order_id", "count"), avg_review=("review_score", "mean"),
                   pct_score_1_2=("review_score", lambda s: 100 * (s <= 2).mean())))
    bucket["pct_orders"] = 100 * bucket.orders / bucket.orders.sum()
    st = (dl.groupby("customer_state")
          .agg(orders=("order_id", "count"), avg_delivery_days=("delivery_days", "mean"),
               median_delivery_days=("delivery_days", "median"), avg_estimated_days=("estimated_days", "mean"),
               late_pct=("is_late", lambda s: 100 * s.mean()), avg_delay_when_late=("delay_days",
                        lambda s: s[s > 0].mean()), avg_freight=("freight_value", "mean"),
               avg_review=("review_score", "mean")).sort_values("orders", ascending=False))
    mo = dl.groupby("purchase_month").agg(orders=("order_id", "count"), avg_delivery_days=("delivery_days", "mean"),
                                          late_pct=("is_late", lambda s: 100 * s.mean()))
    corr = dl[["delivery_days", "review_score"]].dropna()
    corr2 = dl[["delay_days", "review_score"]].dropna()
    same = dl[dl.customer_state == dl.get("seller_state", pd.Series(dtype=object))] if "seller_state" in dl else None
    return {
        "delivered_orders_analyzed": len(dl),
        "delivery_days": num_stats(dl.delivery_days),
        "estimated_days": num_stats(dl.estimated_days),
        "delay_days_vs_estimate": num_stats(dl.delay_days),
        "late_orders_pct": 100 * dl.is_late.mean(),
        "avg_delay_when_late_days": dl.loc[dl.is_late, "delay_days"].mean(),
        "avg_days_early_when_on_time": -dl.loc[~dl.is_late, "delay_days"].mean(),
        "stage_times_days": {"purchase_to_carrier": num_stats(dl.to_carrier_days),
                             "carrier_to_customer": num_stats(dl.last_mile_days)},
        "delay_buckets": records(bucket.round(3)),
        "by_customer_state": records(st.round(3)),
        "by_purchase_month": records(mo.round(3)),
        "correlation_review": {
            "pearson_delivery_days_vs_score": corr.corr().iloc[0, 1] if len(corr) > 2 else None,
            "spearman_delivery_days_vs_score": corr.corr(method="spearman").iloc[0, 1] if len(corr) > 2 else None,
            "pearson_delay_days_vs_score": corr2.corr().iloc[0, 1] if len(corr2) > 2 else None,
        },
        "slowest_states_top5": st[st.orders >= 50].sort_values("avg_delivery_days", ascending=False)
                                 .head(5).index.tolist(),
        "fastest_states_top5": st[st.orders >= 50].sort_values("avg_delivery_days").head(5).index.tolist(),
        "worst_late_states_top5": st[st.orders >= 50].sort_values("late_pct", ascending=False).head(5).index.tolist(),
    }


def sec_geography(D, od, it):
    cust, sel, geo = D["customers"], D["sellers"], D.get("geolocation")
    v = od[od.valid]
    st = (v.groupby("customer_state").agg(orders=("order_id", "count"), customers=("customer_unique_id", "nunique"),
                                          revenue=("items_value", "sum"), avg_ticket=("items_value", "mean"),
                                          avg_freight=("freight_value", "mean"))
          .sort_values("revenue", ascending=False))
    st["revenue_share_pct"] = 100 * st.revenue / st.revenue.sum()
    K["top_state"] = st.index[0] if len(st) else None
    K["top_state_share"] = float(st.revenue_share_pct.iloc[0]) if len(st) else None
    city = (v.groupby(["customer_city", "customer_state"]).agg(orders=("order_id", "count"),
            revenue=("items_value", "sum")).sort_values("orders", ascending=False).head(20))
    vit = it[it.valid == True]  # noqa: E712
    cross = (vit.customer_state != vit.seller_state)
    flow = (vit.groupby(["seller_state", "customer_state"]).size().sort_values(ascending=False).head(15))
    out = {
        "customers_by_state": value_counts(cust["customer_state"]),
        "unique_customers_by_state_top": value_counts(
            cust.drop_duplicates("customer_unique_id")["customer_state"], top=27),
        "sellers_by_state": value_counts(sel["seller_state"]),
        "n_customer_cities": int(cust.customer_city.nunique()),
        "n_seller_cities": int(sel.seller_city.nunique()),
        "revenue_by_customer_state": records(st.round(3)),
        "top20_cities_by_orders": [dict(city=a, state=b, **r) for (a, b), r in city.round(2).iterrows()],
        "cross_state_items_pct": 100 * cross.mean(),
        "top_seller_to_customer_state_flows": [dict(seller_state=a, customer_state=b, items=int(n))
                                               for (a, b), n in flow.items()],
        "freight_by_customer_state": records(vit.groupby("customer_state").freight_value
                                             .agg(["mean", "median"]).round(2).sort_values("mean", ascending=False)),
    }
    if geo is not None:
        out["geolocation"] = {
            "rows": len(geo),
            "unique_zip_prefixes": int(geo.geolocation_zip_code_prefix.nunique()),
            "rows_per_zip_stats": num_stats(geo.groupby("geolocation_zip_code_prefix").size()),
            "duplicate_rows": int(geo.duplicated().sum()),
            "lat_stats": num_stats(geo.geolocation_lat), "lng_stats": num_stats(geo.geolocation_lng),
            "coords_outside_brazil_bbox": int(((geo.geolocation_lat > 6) | (geo.geolocation_lat < -34) |
                                               (geo.geolocation_lng > -34) | (geo.geolocation_lng < -74)).sum()),
            "customer_zips_missing_in_geo_pct": 100 * (~cust.customer_zip_code_prefix.isin(
                set(geo.geolocation_zip_code_prefix))).mean(),
            "seller_zips_missing_in_geo_pct": 100 * (~sel.seller_zip_code_prefix.isin(
                set(geo.geolocation_zip_code_prefix))).mean(),
        }
    return out


def sec_payments(D, od):
    pay = D["order_payments"]
    bytype = (pay.groupby("payment_type").agg(
        payments=("order_id", "count"), orders=("order_id", "nunique"), total_value=("payment_value", "sum"),
        avg_value=("payment_value", "mean"), avg_installments=("payment_installments", "mean")))
    bytype["value_share_pct"] = 100 * bytype.total_value / bytype.total_value.sum()
    bytype["payments_share_pct"] = 100 * bytype.payments / bytype.payments.sum()
    cc = pay[pay.payment_type == "credit_card"]
    both = od[od.items_value.notna() & od.payment_value.notna()]
    diff = both.payment_value - (both.items_value + both.freight_value)
    K["top_payment"] = bytype.sort_values("payments", ascending=False).index[0]
    return {
        "payment_rows": len(pay),
        "by_type": records(bytype.round(3)),
        "installments_distribution": value_counts(pay.payment_installments, top=25),
        "installments_stats": num_stats(pay.payment_installments),
        "credit_card_installments_distribution": value_counts(cc.payment_installments, top=25),
        "credit_card_pct_installments_gt1": 100 * (cc.payment_installments > 1).mean() if len(cc) else None,
        "payment_value_stats": num_stats(pay.payment_value),
        "avg_ticket_by_installments_bucket": records(
            cc.assign(bucket=pd.cut(cc.payment_installments, [0, 1, 3, 6, 10, 24],
                                    labels=["1", "2-3", "4-6", "7-10", "11+"]))
              .groupby("bucket", observed=False).payment_value.agg(["count", "mean"]).round(2)),
        "orders_with_multiple_payment_types_pct": 100 * (od.n_payment_types > 1).sum() / od.n_payment_types.notna().sum(),
        "orders_with_multiple_payment_rows_pct": 100 * (pay.groupby("order_id").size() > 1).mean(),
        "zero_value_payments": int((pay.payment_value == 0).sum()),
        "payment_vs_items_plus_freight": {
            "orders_compared": len(both),
            "pct_within_1_cent": 100 * (diff.abs() <= 0.01).mean(),
            "mean_diff": diff.mean(),
            "pct_paid_more_than_items_plus_freight": 100 * (diff > 0.01).mean(),
            "pct_paid_less_than_items_plus_freight": 100 * (diff < -0.01).mean(),
            "note": "Diferencias suelen deberse a intereses de cuotas y vouchers.",
        },
    }


def sec_reviews(D, od, rv):
    raw = D["order_reviews"]
    r = od[od.review_score.notna()].copy()
    K["avg_review"] = float(r.review_score.mean())
    K["pct_1_2"] = float(100 * (r.review_score <= 2).mean())
    msg = r.review_comment_message.fillna("")
    r["has_comment"] = msg.str.len() > 0
    r["msg_len"] = msg.str.len()
    resp = (rv.review_answer_timestamp - rv.review_creation_date).dt.total_seconds() / 3600

    def top_words(texts, n=30):
        c = Counter()
        for t in texts:
            c.update(w for w in re.findall(r"[a-zà-ú]{3,}", str(t).lower())
                     if w not in PT_STOPWORDS and w not in GOT_HOUSES)
        return [{"word": w, "count": k} for w, k in c.most_common(n)]

    def top_ngrams(texts, size, n=25):
        c = Counter()
        for t in texts:
            ws = re.findall(r"[a-zà-ú]+", str(t).lower())
            for i in range(len(ws) - size + 1):
                g_ = ws[i:i + size]
                if g_[0] in NGRAM_EDGE_STOP or g_[-1] in NGRAM_EDGE_STOP or any(w in GOT_HOUSES for w in g_):
                    continue
                if any(len(w) < 3 for w in (g_[0], g_[-1])):
                    continue
                c.update([" ".join(g_).replace("nao ", "não ")])  # unifica variante sin tilde
        return [{"ngram": w, "count": k} for w, k in c.most_common(n)]

    neg = r.loc[(r.review_score <= 2) & r.has_comment, "review_comment_message"]
    pos = r.loc[(r.review_score >= 4) & r.has_comment, "review_comment_message"]
    return {
        "raw_review_rows": len(raw),
        "unique_review_ids": int(raw.review_id.nunique()),
        "duplicated_review_ids": int(raw.review_id.duplicated().sum()),
        "orders_with_multiple_reviews": int((raw.groupby("order_id").size() > 1).sum()),
        "orders_with_review_pct": 100 * od.review_score.notna().mean(),
        "score_distribution": value_counts(r.review_score.astype(int)),
        "avg_score": r.review_score.mean(),
        "score_stats": num_stats(r.review_score),
        "pct_5_stars": 100 * (r.review_score == 5).mean(),
        "pct_1_2_stars": 100 * (r.review_score <= 2).mean(),
        "pct_with_title": 100 * r.review_comment_title.notna().mean(),
        "pct_with_message": 100 * r.has_comment.mean(),
        "score_by_has_comment": r.groupby("has_comment").review_score.agg(["count", "mean"]).round(3)
                                 .rename(index=str).to_dict("index"),
        "comment_length_stats": num_stats(r.loc[r.has_comment, "msg_len"]),
        "comment_length_by_score": r[r.has_comment].groupby("review_score").msg_len.mean().round(1).to_dict(),
        "survey_response_time_hours": num_stats(resp),
        "score_by_order_status": r.groupby("order_status").review_score.agg(["count", "mean"]).round(3)
                                  .to_dict("index"),
        "score_by_month": r.groupby("purchase_month").review_score.agg(["count", "mean"]).round(3).to_dict("index"),
        "score_by_n_items": r.groupby(r.n_items.clip(upper=5)).review_score.agg(["count", "mean"]).round(3)
                             .rename(index=lambda x: str(int(x))).to_dict("index"),
        "score_by_multi_seller": r.groupby(r.n_sellers > 1).review_score.agg(["count", "mean"]).round(3)
                                  .rename(index=str).to_dict("index"),
        "score_by_customer_state": records(r.groupby("customer_state").review_score
                                           .agg(["count", "mean"]).round(3).sort_values("mean")),
        "top_words_negative_reviews_1_2_stars": top_words(neg),
        "top_words_positive_reviews_4_5_stars": top_words(pos),
        "top_bigrams_negative_reviews_1_2_stars": top_ngrams(neg, 2),
        "top_trigrams_negative_reviews_1_2_stars": top_ngrams(neg, 3),
        "top_bigrams_positive_reviews_4_5_stars": top_ngrams(pos, 2),
        "top_trigrams_positive_reviews_4_5_stars": top_ngrams(pos, 3),
        "text_note": "Texto en portugués; stopwords y nombres de casas de Game of Thrones (anonimización) filtrados. "
                     "Para NLP serio usar lematización.",
    }


def sec_products(D, p, it):
    prod = D["products"]
    v = it[it.valid == True]  # noqa: E712
    cat = (v.groupby("category").agg(items=("order_id", "count"), orders=("order_id", "nunique"),
                                     revenue=("price", "sum"), avg_price=("price", "mean"),
                                     avg_freight=("freight_value", "mean"), avg_review=("review_score", "mean"),
                                     late_pct=("is_late", lambda s: 100 * s.mean()),
                                     n_sellers=("seller_id", "nunique"), n_products=("product_id", "nunique")))
    cat["revenue_share_pct"] = 100 * cat.revenue / cat.revenue.sum()
    cat["freight_to_price_pct"] = 100 * cat.avg_freight / cat.avg_price
    cat = cat.sort_values("revenue", ascending=False)
    K["top_category"] = cat.index[0] if len(cat) else None
    K["top_category_share"] = float(cat.revenue_share_pct.iloc[0]) if len(cat) else None
    big = cat[cat.orders >= 100]
    attrs = ["product_name_lenght", "product_description_lenght", "product_photos_qty", "product_weight_g",
             "product_length_cm", "product_height_cm", "product_width_cm"]
    attrs = [a for a in attrs if a in prod.columns]
    sold = v.groupby("product_id").agg(units=("order_id", "count"), revenue=("price", "sum")) \
            .sort_values("revenue", ascending=False)
    return {
        "n_products": len(prod),
        "n_categories": int(p.category.nunique()),
        "missing_category_pct": 100 * prod.product_category_name.isna().mean(),
        "categories_without_translation": (
            prod[prod.product_category_name.notna()
                 & ~prod.product_category_name.isin(set(D["translation"].product_category_name))]
            .product_category_name.value_counts().to_dict() if "translation" in D else None),
        "products_per_category_top15": p.category.value_counts().head(15).to_dict(),
        "physical_attributes": {a: num_stats(prod[a]) for a in attrs},
        "zero_weight_products": int((prod.get("product_weight_g", pd.Series(dtype=float)) == 0).sum()),
        "category_ranking_by_revenue_top25": records(cat.head(25).round(3)),
        "category_concentration": concentration(cat.revenue.values),
        "best_rated_categories_min100_orders": records(big.sort_values("avg_review", ascending=False)
                                                       [["orders", "revenue", "avg_review", "late_pct"]].head(10).round(3)),
        "worst_rated_categories_min100_orders": records(big.sort_values("avg_review")
                                                        [["orders", "revenue", "avg_review", "late_pct"]].head(10).round(3)),
        "highest_priced_categories_min100_orders": records(big.sort_values("avg_price", ascending=False)
                                                           [["orders", "avg_price"]].head(10).round(2)),
        "highest_freight_burden_categories_min100_orders": records(big.sort_values("freight_to_price_pct", ascending=False)
                                                                   [["orders", "freight_to_price_pct"]].head(10).round(2)),
        "product_concentration": concentration(sold.revenue.values),
        "top10_products_by_revenue": records(sold.head(10).round(2)),
        "products_sold_once_pct": 100 * (sold.units == 1).mean() if len(sold) else None,
        "products_never_sold": int(len(set(prod.product_id) - set(sold.index))),
        "photos_qty_vs_units_corr_spearman": (
            prod.merge(sold, left_on="product_id", right_index=True)[["product_photos_qty", "units"]]
            .corr(method="spearman").iloc[0, 1] if "product_photos_qty" in prod.columns else None),
    }


def sec_sellers(D, it):
    v = it[it.valid == True]  # noqa: E712
    s = (v.groupby("seller_id").agg(items=("order_id", "count"), orders=("order_id", "nunique"),
                                    revenue=("price", "sum"), avg_price=("price", "mean"),
                                    avg_review=("review_score", "mean"),
                                    late_pct=("is_late", lambda x: 100 * x.mean()),
                                    n_products=("product_id", "nunique"), n_categories=("category", "nunique"),
                                    state=("seller_state", "first"))
         .sort_values("revenue", ascending=False))
    conc = concentration(s.revenue.values)
    K["top10_sellers_share"] = conc.get("top10_share_pct")
    K["n_active_sellers"] = len(s)
    bystate = (s.groupby("state").agg(sellers=("revenue", "count"), revenue=("revenue", "sum"),
                                      avg_review=("avg_review", "mean")).sort_values("revenue", ascending=False))
    bystate["revenue_share_pct"] = 100 * bystate.revenue / bystate.revenue.sum()
    seg = pd.cut(s.orders, [0, 1, 5, 20, 100, np.inf], labels=["1", "2-5", "6-20", "21-100", ">100"])
    segs = s.groupby(seg, observed=False).agg(sellers=("revenue", "count"), revenue=("revenue", "sum"))
    segs["revenue_share_pct"] = 100 * segs.revenue / segs.revenue.sum()
    rated = s[s.orders >= 30]
    return {
        "registered_sellers": len(D["sellers"]),
        "active_sellers": len(s),
        "inactive_sellers_pct": 100 * (1 - len(s) / len(D["sellers"])),
        "concentration": conc,
        "revenue_per_seller_stats": num_stats(s.revenue),
        "orders_per_seller_stats": num_stats(s.orders),
        "seller_segments_by_order_volume": records(segs.round(3)),
        "top15_sellers": records(s.head(15).round(3)),
        "by_state": records(bystate.round(3)),
        "avg_categories_per_seller": s.n_categories.mean(),
        "single_category_sellers_pct": 100 * (s.n_categories == 1).mean(),
        "sellers_min30_orders": {
            "count": len(rated),
            "avg_review_stats": num_stats(rated.avg_review),
            "worst10_by_review": records(rated.sort_values("avg_review").head(10).round(3)),
            "late_pct_stats": num_stats(rated.late_pct),
            "corr_late_pct_vs_review": rated[["late_pct", "avg_review"]].corr().iloc[0, 1] if len(rated) > 2 else None,
        },
    }


def sec_customers(D, od):
    cust = D["customers"]
    v = od[od.valid & od.customer_unique_id.notna()].sort_values("order_purchase_timestamp").copy()
    g = v.groupby("customer_unique_id")
    n = g.size()
    spend = g.items_value.sum()
    v["rank"] = g.cumcount()
    first = v[v["rank"] == 0].set_index("customer_unique_id").order_purchase_timestamp
    second = v[v["rank"] == 1].set_index("customer_unique_id").order_purchase_timestamp
    gap = (second - first.reindex(second.index)).dt.days
    K["repeat_rate"] = float(100 * (n > 1).mean())
    K["unique_customers"] = int(len(n))
    cohort = v[v["rank"] == 0].assign(cohort=lambda d: d.order_purchase_timestamp.dt.to_period("M").astype(str))
    cohort["repeat"] = cohort.customer_unique_id.map(n) > 1
    coh = cohort.groupby("cohort").agg(size=("repeat", "size"), repeat_pct=("repeat", lambda s: 100 * s.mean()))
    ref = v.order_purchase_timestamp.max()
    rec = (ref - g.order_purchase_timestamp.max()).dt.days
    sp_sorted = spend.sort_values(ascending=False)
    top20 = sp_sorted.head(max(1, len(sp_sorted) // 5)).sum() / sp_sorted.sum() * 100 if sp_sorted.sum() else None
    rep_state = v.assign(rep=v.customer_unique_id.map(n) > 1).drop_duplicates("customer_unique_id") \
                 .groupby("customer_state").rep.agg(["size", "mean"])
    rep_state["mean"] *= 100
    return {
        "customer_ids": int(cust.customer_id.nunique()),
        "unique_customers_total": int(cust.customer_unique_id.nunique()),
        "unique_customers_with_valid_orders": len(n),
        "customer_id_per_unique_ratio": cust.customer_id.nunique() / cust.customer_unique_id.nunique(),
        "orders_per_customer_distribution": value_counts(n.clip(upper=5), top=5),
        "repeat_customers_pct": 100 * (n > 1).mean(),
        "customers_with_3plus_orders_pct": 100 * (n >= 3).mean(),
        "days_between_first_and_second_order": num_stats(gap),
        "repurchase_within_30_days_pct_of_repeaters": 100 * (gap <= 30).mean() if len(gap) else None,
        "repurchase_within_90_days_pct_of_repeaters": 100 * (gap <= 90).mean() if len(gap) else None,
        "spend_per_customer_stats": num_stats(spend),
        "top20pct_customers_share_of_revenue_pct": top20,
        "spend_concentration": concentration(spend.values),
        "recency_days_stats": num_stats(rec),
        "recency_reference_date": ref,
        "first_order_cohorts_min100": records(coh[coh["size"] >= 100].round(3)),
        "repeat_rate_by_state_min200": records(rep_state[rep_state["size"] >= 200].sort_values("mean", ascending=False)
                                               .round(3)),
        "note": "Con ~3% de recompra el dataset es dominado por compradores de una sola vez.",
    }


def sec_cross_insights(od, it):
    """Relaciones entre dimensiones útiles para modelado."""
    dl = od[(od.order_status == "delivered") & od.review_score.notna() & od.delay_days.notna()].copy()
    dl["low"] = dl.review_score <= 2
    num = dl[["review_score", "delivery_days", "delay_days", "estimated_days", "items_value", "freight_value",
              "n_items", "payment_value", "max_installments", "approval_hours"]].dropna()
    out = {"correlation_matrix_spearman": num.corr(method="spearman").round(3).to_dict() if len(num) > 3 else None}
    freight_q = pd.qcut(dl.freight_value.dropna(), 4, duplicates="drop")
    out["low_score_pct_by_freight_quartile"] = {str(k): round(100 * x, 2) for k, x in
                                                dl.loc[freight_q.index].groupby(freight_q, observed=False).low.mean().items()}
    price_q = pd.qcut(dl.items_value.dropna(), 4, duplicates="drop")
    out["low_score_pct_by_order_value_quartile"] = {str(k): round(100 * x, 2) for k, x in
                                                    dl.loc[price_q.index].groupby(price_q, observed=False).low.mean().items()}
    out["low_score_pct_late_vs_ontime"] = {"late": 100 * dl[dl.is_late].low.mean(),
                                           "on_time": 100 * dl[~dl.is_late].low.mean()}
    return out


def sec_findings():
    f = []
    g = K.get
    if g("n_orders"):
        f.append(f"{g('n_orders'):,} pedidos totales, {g('n_valid_orders'):,} válidos; {g('unique_customers', 0):,} clientes únicos.")
    if g("gmv"):
        f.append(f"GMV (sin flete): {g('gmv'):,.0f} BRL; flete total: {g('freight_total', 0):,.0f} BRL.")
    if g("late_pct") is not None:
        f.append(f"{g('late_pct'):.1f}% de los pedidos entregados llegó después de la fecha estimada; "
                 f"entrega promedio {g('avg_delivery_days'):.1f} días.")
    if g("avg_review"):
        f.append(f"Review promedio {g('avg_review'):.2f}; {g('pct_1_2'):.1f}% son 1-2 estrellas.")
    if g("top_state"):
        f.append(f"El estado {g('top_state')} concentra {g('top_state_share'):.1f}% de los ingresos.")
    if g("top_category"):
        f.append(f"Categoría líder: {g('top_category')} ({g('top_category_share'):.1f}% de los ingresos).")
    if g("top10_sellers_share") is not None:
        f.append(f"Los 10 mayores vendedores aportan {g('top10_sellers_share'):.1f}% de los ingresos "
                 f"(de {g('n_active_sellers'):,} activos).")
    if g("repeat_rate") is not None:
        f.append(f"Solo {g('repeat_rate'):.1f}% de los clientes únicos compró más de una vez.")
    if g("top_payment"):
        f.append(f"Medio de pago más usado: {g('top_payment')}.")
    if g("avg_dist_km") is not None:
        f.append(f"Distancia media vendedor-cliente: {g('avg_dist_km'):.0f} km; correlación (Spearman) distancia-flete "
                 f"{g('dist_freight_corr'):.2f} y distancia-días de entrega {g('dist_delivery_corr'):.2f}.")
    if g("freight_model_r2") is not None:
        f.append(f"Un modelo log-log (distancia, peso, volumen, precio) explica R²={g('freight_model_r2'):.2f} del flete.")
    if g("late_to_carrier_pct") is not None:
        f.append(f"{g('late_to_carrier_pct'):.1f}% de los ítems se entregó al transportista después del límite del vendedor.")
    return f


# ----------------------------------------------------------------------------
# Distancia, flete, cumplimiento, canasta, RFM, outliers  (v2)
# ----------------------------------------------------------------------------
def haversine(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dphi = p2 - p1
    dl = np.radians(lon2) - np.radians(lon1)
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def add_distance(D, it):
    """Distancia vendedor->cliente (km) usando el centroide de lat/lng por prefijo de CP."""
    it = it.copy()
    geo = D.get("geolocation")
    if geo is None:
        it["dist_km"] = np.nan
        return it
    g = geo[geo.geolocation_lat.between(BBOX[0], BBOX[1]) & geo.geolocation_lng.between(BBOX[2], BBOX[3])]
    cent = g.groupby("geolocation_zip_code_prefix")[["geolocation_lat", "geolocation_lng"]].mean()
    c = cent.rename(columns={"geolocation_lat": "c_lat", "geolocation_lng": "c_lng"})
    s = cent.rename(columns={"geolocation_lat": "s_lat", "geolocation_lng": "s_lng"})
    it = (it.merge(c, left_on="customer_zip_code_prefix", right_index=True, how="left")
            .merge(s, left_on="seller_zip_code_prefix", right_index=True, how="left"))
    it["dist_km"] = haversine(it.s_lat, it.s_lng, it.c_lat, it.c_lng)
    return it.drop(columns=["c_lat", "c_lng", "s_lat", "s_lng"])


def sec_distance(it):
    x = it[it.valid == True]  # noqa: E712
    if x.dist_km.notna().sum() == 0:
        return {"note": "Sin geolocalización: no se pudo calcular distancia."}
    K["avg_dist_km"] = float(x.dist_km.mean())
    o = x[x.order_status == "delivered"].drop_duplicates("order_id")  # distancia del primer ítem del pedido
    o = o.assign(bucket=pd.cut(o.dist_km, DIST_BINS, labels=DIST_LABELS))
    b = (o.groupby("bucket", observed=False)
          .agg(orders=("order_id", "count"), avg_freight_per_item=("freight_value", "mean"),
               avg_price=("price", "mean"), avg_delivery_days=("delivery_days", "mean"),
               late_pct=("is_late", lambda s: 100 * s.mean()), avg_review=("review_score", "mean")))
    b["pct_orders"] = 100 * b.orders / b.orders.sum()
    cols = ["dist_km", "freight_value", "delivery_days", "delay_days", "review_score"]
    corr = o[cols].corr(method="spearman")
    K["dist_freight_corr"] = float(corr.loc["dist_km", "freight_value"])
    K["dist_delivery_corr"] = float(corr.loc["dist_km", "delivery_days"])
    same = x.customer_state == x.seller_state
    return {
        "method": "haversine entre centroides de CP (vendedor->cliente); geolocation filtrada al bbox de Brasil",
        "coverage_pct_items_with_distance": 100 * x.dist_km.notna().mean(),
        "distance_km_stats": num_stats(x.dist_km),
        "same_state_items_pct": 100 * same.mean(),
        "avg_distance_same_state_km": x.loc[same, "dist_km"].mean(),
        "avg_distance_cross_state_km": x.loc[~same, "dist_km"].mean(),
        "by_distance_bucket_delivered_orders": records(b.round(3)),
        "spearman_correlations_order_level": corr.round(3).to_dict(),
        "note": "Medidas por pedido usando el primer ítem; freight_value es por ítem.",
    }


def sec_freight_model(it):
    x = it[it.valid == True].copy()  # noqa: E712
    free_pct = 100 * (x.freight_value == 0).mean()
    m = x[(x.freight_value > 0) & (x.product_weight_g > 0) & (x.volume_cm3 > 0) & (x.price > 0)
          & x.dist_km.notna()]
    if len(m) < 50:
        return {"free_shipping_items_pct": free_pct, "note": "Datos insuficientes para el modelo."}
    feats = {"log1p_dist_km": np.log1p(m.dist_km), "log_weight_g": np.log(m.product_weight_g),
             "log_volume_cm3": np.log(m.volume_cm3), "log_price": np.log(m.price)}
    y = np.log(m.freight_value.values)

    def ols(cols):
        X = np.column_stack([np.ones(len(m))] + [feats[c].values for c in cols])
        beta = np.linalg.lstsq(X, y, rcond=None)[0]
        r2 = 1 - ((y - X @ beta) ** 2).sum() / ((y - y.mean()) ** 2).sum()
        return beta, float(r2)

    beta, r2 = ols(list(feats))
    wb = pd.cut(m.product_weight_g, [0, 500, 1000, 2000, 5000, 10000, np.inf],
                labels=["<500g", "500g-1kg", "1-2kg", "2-5kg", "5-10kg", ">10kg"])
    byw = (m.groupby(wb, observed=False).agg(items=("price", "count"), avg_freight=("freight_value", "mean"),
                                             median_freight=("freight_value", "median"), avg_price=("price", "mean")))
    byw["freight_to_price_pct"] = 100 * byw.avg_freight / byw.avg_price
    K["freight_model_r2"] = r2
    return {
        "free_shipping_items_pct": free_pct,
        "rows_used": len(m),
        "model": "OLS: log(freight) ~ log1p(dist_km) + log(weight_g) + log(volume_cm3) + log(price)",
        "coefficients": dict(zip(["intercept"] + list(feats), [float(b) for b in beta])),
        "r2_full": r2,
        "r2_single_feature": {c: ols([c])[1] for c in feats},
        "spearman_freight_vs": {"dist_km": float(m.freight_value.corr(m.dist_km, method="spearman")),
                                "weight_g": float(m.freight_value.corr(m.product_weight_g, method="spearman")),
                                "volume_cm3": float(m.freight_value.corr(m.volume_cm3, method="spearman")),
                                "price": float(m.freight_value.corr(m.price, method="spearman"))},
        "by_weight_bucket": records(byw.round(3)),
    }


def sec_seller_compliance(it):
    x = it[(it.valid == True) & it.order_delivered_carrier_date.notna()  # noqa: E712
           & it.shipping_limit_date.notna()].copy()
    x["carrier_delay_days"] = (x.order_delivered_carrier_date - x.shipping_limit_date).dt.total_seconds() / 86400
    x["late_to_carrier"] = x.carrier_delay_days > 0
    x["handling_window_days"] = (x.shipping_limit_date - x.order_purchase_timestamp).dt.total_seconds() / 86400
    K["late_to_carrier_pct"] = float(100 * x.late_to_carrier.mean())
    grp = (x.groupby("late_to_carrier")
            .agg(items=("order_id", "count"), customer_late_pct=("is_late", lambda s: 100 * s.mean()),
                 avg_review=("review_score", "mean"), avg_delivery_days=("delivery_days", "mean"))
            .rename(index=str))
    st = (x.groupby("seller_state").agg(items=("order_id", "count"),
                                        late_to_carrier_pct=("late_to_carrier", lambda s: 100 * s.mean()))
          .sort_values("items", ascending=False))
    ps = x.groupby("seller_id").agg(items=("order_id", "count"), late=("late_to_carrier", "mean"))
    ps = ps[ps["items"] >= 30]
    return {
        "items_analyzed": len(x),
        "late_to_carrier_pct": 100 * x.late_to_carrier.mean(),
        "carrier_delay_days_stats": num_stats(x.carrier_delay_days),
        "seller_handling_window_days_stats": num_stats(x.handling_window_days),
        "customer_outcomes_by_seller_compliance": grp.round(3).to_dict("index"),
        "by_seller_state": records(st.round(3)),
        "sellers_min30_items": {"count": len(ps),
                                "pct_with_over_20pct_late_to_carrier": 100 * (ps.late > 0.2).mean() if len(ps) else None},
        "definition": "late_to_carrier = order_delivered_carrier_date > shipping_limit_date",
    }


def sec_basket(od, it):
    v = it[it.valid == True]  # noqa: E712
    u = v[["order_id", "category"]].drop_duplicates()
    ncat = u.groupby("order_id").size()
    nitems = v.groupby("order_id").size()
    multi_ids = ncat[ncat >= 2].index
    pairs = Counter()
    for cs in u[u.order_id.isin(multi_ids)].groupby("order_id").category.apply(list):
        pairs.update(combinations(sorted(cs), 2))
    # categoría del primer ítem del primer pedido vs recompra
    vv = od[od.valid & od.customer_unique_id.notna()].sort_values("order_purchase_timestamp")
    cnt = vv.groupby("customer_unique_id").size()
    first = vv.drop_duplicates("customer_unique_id")[["order_id", "customer_unique_id"]]
    f = first.merge(it[it.order_item_id == 1][["order_id", "category"]], on="order_id")
    f["repeat"] = f.customer_unique_id.map(cnt) > 1
    rc = f.groupby("category").agg(customers=("repeat", "size"), repeat_pct=("repeat", lambda s: 100 * s.mean()))
    rc = rc[rc.customers >= 300].sort_values("repeat_pct", ascending=False)
    return {
        "multi_category_orders_pct": 100 * len(multi_ids) / len(ncat),
        "multi_item_single_category_orders_pct": 100 * ((nitems >= 2) & (ncat == 1)).sum() / len(ncat),
        "top15_category_pairs": [{"a": a, "b": b, "orders": n} for (a, b), n in pairs.most_common(15)],
        "first_order_category_repeat_rate_min300_customers": {
            "highest": records(rc.head(8).round(2)), "lowest": records(rc.tail(8).round(2))},
    }


def sec_rfm(od):
    v = od[od.valid & od.customer_unique_id.notna() & od.items_value.notna()]
    ref = v.order_purchase_timestamp.max()
    g = v.groupby("customer_unique_id")
    c = pd.DataFrame({"recency_days": (ref - g.order_purchase_timestamp.max()).dt.days,
                      "frequency": g.size(), "monetary": g.items_value.sum()})
    c["recency_bucket"] = pd.cut(c.recency_days, [-1, 90, 180, 365, np.inf],
                                 labels=["0-90d", "91-180d", "181-365d", ">365d"])
    c["value_tier"] = pd.cut(c.monetary.rank(pct=True), [0, 1 / 3, 2 / 3, 1], labels=["low", "mid", "high"])
    mat = (c.groupby(["recency_bucket", "value_tier"], observed=False)
            .agg(customers=("monetary", "count"), revenue=("monetary", "sum")).reset_index())
    mat["pct_customers"] = 100 * mat.customers / mat.customers.sum()
    mat["pct_revenue"] = 100 * mat.revenue / mat.revenue.sum()
    rep = c.frequency > 1
    return {
        "reference_date": ref,
        "matrix_recency_x_value": [{k: (str(val) if k in ("recency_bucket", "value_tier") else val)
                                    for k, val in r.items()} for r in mat.round(3).to_dict("records")],
        "repeaters_revenue_share_pct": 100 * c.loc[rep, "monetary"].sum() / c.monetary.sum(),
        "one_time_buyers_revenue_share_pct": 100 * c.loc[~rep, "monetary"].sum() / c.monetary.sum(),
        "frequency_stats": num_stats(c.frequency),
        "monetary_stats": num_stats(c.monetary),
        "recency_stats": num_stats(c.recency_days),
        "definition": "Recencia respecto de la última compra del dataset; M = suma de price (sin flete).",
    }


def sec_outliers(od, it):
    v = od[od.valid & od.items_value.notna()]
    x = it[it.valid == True]  # noqa: E712
    dl = od[od.delivery_days.notna()]
    return {
        "top10_orders_by_value": records(v.nlargest(10, "items_value")[
            ["order_id", "items_value", "freight_value", "n_items", "customer_state", "review_score"]].round(2)),
        "top10_items_by_price": records(x.nlargest(10, "price")[
            ["order_id", "product_id", "category", "price", "freight_value", "seller_state"]].round(2)),
        "top10_items_by_freight": records(x.nlargest(10, "freight_value")[
            ["order_id", "category", "price", "freight_value", "customer_state", "seller_state"]].round(2)),
        "orders_delivery_over_60_days": int((dl.delivery_days > 60).sum()),
        "slowest_5_deliveries": records(dl.nlargest(5, "delivery_days")[
            ["order_id", "delivery_days", "estimated_days", "customer_state", "review_score"]].round(1)),
        "items_price_over_p99_pct_of_revenue": 100 * x[x.price > x.price.quantile(0.99)].price.sum() / x.price.sum(),
    }


def sec_nulls_by_status(od):
    cols = ["order_approved_at", "order_delivered_carrier_date", "order_delivered_customer_date"]
    return {"null_pct_by_order_status": od.groupby("order_status")[cols]
            .agg(lambda s: 100 * s.isna().mean()).round(2).to_dict("index"),
            "orders_per_status": od.order_status.value_counts().to_dict()}


def sec_domains(D, p):
    tr = D.get("translation")
    return {
        "order_status": sorted(D["orders"].order_status.dropna().unique().tolist()),
        "payment_types": sorted(D["order_payments"].payment_type.dropna().unique().tolist()),
        "review_scores": sorted(D["order_reviews"].review_score.dropna().astype(int).unique().tolist()),
        "customer_states": sorted(D["customers"].customer_state.dropna().unique().tolist()),
        "seller_states": sorted(D["sellers"].seller_state.dropna().unique().tolist()),
        "categories_english": sorted(p.category.dropna().unique().tolist()),
        "category_translation_pt_to_en": (dict(zip(tr.product_category_name, tr.product_category_name_english))
                                          if tr is not None else None),
    }


def sec_samples(D, n):
    out = {}
    for name, df in D.items():
        s = df.sample(min(n, len(df)), random_state=1)
        out[name] = [{k: (v[:80] if isinstance(v, str) else v) for k, v in r.items()}
                     for r in s.to_dict("records")]
    return out


def sec_reconciliation(D, od, it):
    return {
        "order_items_rows_total": len(D["order_items"]),
        "order_items_rows_in_valid_orders": int((it.valid == True).sum()),  # noqa: E712
        "orders_total": len(od), "orders_valid": int(od.valid.sum()),
        "orders_delivered_status": int((od.order_status == "delivered").sum()),
        "orders_delivered_with_date_analyzed": int(((od.order_status == "delivered")
                                                    & od.order_delivered_customer_date.notna()).sum()),
        "customer_ids": int(D["customers"].customer_id.nunique()),
        "unique_customers": int(D["customers"].customer_unique_id.nunique()),
        "reviews_raw_rows": len(D["order_reviews"]), "orders_with_review": int(od.review_score.notna().sum()),
        "explanation": "Valid = excluye canceled/unavailable. Delivered analizado exige fecha real de entrega. "
                       "Reviews: se usa la más reciente por pedido.",
    }


def sec_repro(args, D):
    return {"script_version": SCRIPT_VERSION, "python": platform.python_version(), "pandas": pd.__version__,
            "numpy": np.__version__, "args": vars(args),
            "parameters": {"MIN_MONTH_ORDERS": MIN_MONTH_ORDERS, "BBOX_lat_lat_lng_lng": BBOX,
                           "distance_bins_km": DIST_LABELS},
            "csv_sizes_mb": {k: round(os.path.getsize(os.path.join(args.data_dir, f)) / 1e6, 2)
                             for k, f in FILES.items() if k in D}}


# ----------------------------------------------------------------------------
# Contexto estático (capa semántica)
# ----------------------------------------------------------------------------
DATASET_CONTEXT = {
    "name": "Brazilian E-Commerce Public Dataset by Olist",
    "source": "https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce",
    "license": "Ver la página de Kaggle (a la fecha de esta documentación figura como CC BY-NC-SA 4.0; verificar).",
    "summary": "~100k pedidos reales (2016-2018) de Olist Store en marketplaces brasileños. Permite ver un pedido por "
               "estado, precio, pago, flete, ubicación del cliente, atributos del producto y reviews.",
    "business_model": "Olist conecta pequeños comercios con marketplaces mediante un único contrato; el vendedor "
                      "recibe la notificación, despacha con logística de Olist y, al recibir el producto (o vencer "
                      "la fecha estimada), el cliente recibe una encuesta de satisfacción por email.",
    "anonymization": "Datos reales anonimizados. Los nombres de tiendas/socios en los textos de reviews se "
                     "reemplazaron por casas de Game of Thrones (Lannister, Stark, Targaryen...). "
                     "Los IDs son hashes. No incluye texto libre identificable.",
    "related_data": "Existe un Marketing Funnel Dataset de Olist que se puede unir por seller_id. "
                    "El 'classified dataset' fue retirado en la versión 6.",
    "cardinality_notes": ["Un pedido puede tener varios ítems.", "Cada ítem puede ser de un vendedor distinto."],
    "tables": {
        "orders": {"file": FILES["orders"], "grain": "1 fila por pedido", "pk": ["order_id"],
                   "columns": {
                       "order_id": "ID único del pedido",
                       "customer_id": "FK->customers.customer_id; cambia en cada pedido (no identifica a la persona)",
                       "order_status": "created|approved|invoiced|processing|shipped|delivered|unavailable|canceled",
                       "order_purchase_timestamp": "momento de la compra",
                       "order_approved_at": "aprobación del pago",
                       "order_delivered_carrier_date": "entrega del vendedor al transportista",
                       "order_delivered_customer_date": "entrega real al cliente (nula si no se entregó)",
                       "order_estimated_delivery_date": "fecha estimada informada al cliente al comprar"}},
        "order_items": {"file": FILES["order_items"], "grain": "1 fila por ítem de pedido",
                        "pk": ["order_id", "order_item_id"],
                        "columns": {
                            "order_id": "FK->orders", "order_item_id": "número de secuencia del ítem dentro del pedido",
                            "product_id": "FK->products", "seller_id": "FK->sellers",
                            "shipping_limit_date": "fecha límite del vendedor para entregar al transportista",
                            "price": "precio del ítem en BRL (sin flete)",
                            "freight_value": "flete del ítem en BRL; para flete por pedido hay que sumar los ítems"}},
        "order_payments": {"file": FILES["order_payments"], "grain": "1 fila por pago (un pedido puede tener varios)",
                           "pk": ["order_id", "payment_sequential"],
                           "columns": {
                               "order_id": "FK->orders", "payment_sequential": "secuencia cuando se combinan medios",
                               "payment_type": "credit_card|boleto|voucher|debit_card|not_defined",
                               "payment_installments": "cantidad de cuotas",
                               "payment_value": "monto pagado en BRL"}},
        "order_reviews": {"file": FILES["order_reviews"], "grain": "1 fila por review",
                          "pk": ["review_id", "order_id"],
                          "columns": {
                              "review_id": "ID de review (NO es único: se repite en algunos pedidos)",
                              "order_id": "FK->orders (algunos pedidos tienen más de una review)",
                              "review_score": "1 a 5", "review_comment_title": "título opcional (portugués)",
                              "review_comment_message": "comentario opcional (portugués)",
                              "review_creation_date": "envío de la encuesta",
                              "review_answer_timestamp": "momento en que respondió"}},
        "customers": {"file": FILES["customers"], "grain": "1 fila por customer_id (= 1 por pedido)",
                      "pk": ["customer_id"],
                      "columns": {
                          "customer_id": "clave de unión con orders; una persona tiene varios si compra varias veces",
                          "customer_unique_id": "identifica a la persona; usar para recompra y clientes únicos",
                          "customer_zip_code_prefix": "primeros 5 dígitos del CP",
                          "customer_city": "ciudad", "customer_state": "UF (sigla del estado)"}},
        "sellers": {"file": FILES["sellers"], "grain": "1 fila por vendedor", "pk": ["seller_id"],
                    "columns": {"seller_id": "ID del vendedor", "seller_zip_code_prefix": "prefijo de CP (5 dígitos)",
                                "seller_city": "ciudad", "seller_state": "UF"}},
        "products": {"file": FILES["products"], "grain": "1 fila por producto", "pk": ["product_id"],
                     "columns": {
                         "product_id": "ID del producto",
                         "product_category_name": "categoría en portugués (nula en ~2% de productos)",
                         "product_name_lenght": "cantidad de caracteres del nombre (typo 'lenght' original)",
                         "product_description_lenght": "caracteres de la descripción (typo original)",
                         "product_photos_qty": "cantidad de fotos",
                         "product_weight_g": "peso en gramos",
                         "product_length_cm": "largo en cm", "product_height_cm": "alto en cm",
                         "product_width_cm": "ancho en cm"}},
        "geolocation": {"file": FILES["geolocation"],
                        "grain": "VARIAS filas por prefijo de CP (muchas duplicadas)", "pk": None,
                        "columns": {"geolocation_zip_code_prefix": "prefijo de CP (une con customers y sellers)",
                                    "geolocation_lat": "latitud", "geolocation_lng": "longitud",
                                    "geolocation_city": "ciudad", "geolocation_state": "UF"}},
        "translation": {"file": FILES["translation"], "grain": "1 fila por categoría", "pk": ["product_category_name"],
                        "columns": {"product_category_name": "categoría en portugués",
                                    "product_category_name_english": "categoría en inglés"}},
    },
    "joins": [
        "orders.customer_id = customers.customer_id",
        "order_items.order_id = orders.order_id",
        "order_items.product_id = products.product_id",
        "order_items.seller_id = sellers.seller_id",
        "order_payments.order_id = orders.order_id",
        "order_reviews.order_id = orders.order_id",
        "products.product_category_name = translation.product_category_name",
        "customers.customer_zip_code_prefix = geolocation.geolocation_zip_code_prefix (agregar antes: 1 fila por CP)",
        "sellers.seller_zip_code_prefix = geolocation.geolocation_zip_code_prefix (agregar antes: 1 fila por CP)",
    ],
    "gotchas": [
        "Clientes únicos y recompra: usar customer_unique_id, nunca customer_id.",
        "geolocation tiene varias filas por CP: agregar (centroide/mediana) antes de unir o se multiplican filas.",
        "Unir order_items con order_payments directamente duplica montos: agregar primero a nivel pedido.",
        "review_id se repite y hay pedidos con más de una review: dedupe por order_id (más reciente).",
        "order_item_id es un contador dentro del pedido, no un ID de ítem.",
        "freight_value está por ítem; el flete del pedido es la suma.",
        "Categorías sin traducción en la tabla translation: ver products_and_categories.categories_without_translation.",
        "Los nulos en fechas de entrega dependen del estado del pedido: ver nulls_by_status.",
        "Hay pedidos con fechas incoherentes (p. ej. carrier antes de la compra): ver orders.temporal_anomalies.",
        "Cobertura temporal irregular: los primeros y últimos meses tienen muy pocos pedidos y hay meses sin datos; "
        "ver sales.monthly[].partial_coverage. No calcular crecimientos con esos meses.",
        "Los textos están en portugués; los nombres de casas de Game of Thrones son ruido de anonimización.",
        "Las métricas de entrega/atraso solo consideran pedidos delivered con fecha real (no incluyen pedidos "
        "cancelados ni en tránsito).",
    ],
    "definitions": {
        "valid_orders": "todos salvo canceled y unavailable",
        "revenue_gmv": "suma de order_items.price (sin flete)",
        "is_late": "order_delivered_customer_date > order_estimated_delivery_date",
        "delay_days": "entrega real - estimada, en días (positivo = tarde)",
        "delivery_days": "entrega real - compra, en días",
        "late_to_carrier": "order_delivered_carrier_date > shipping_limit_date",
        "dist_km": "haversine entre centroides de CP vendedor y cliente",
        "review": "la más reciente por pedido",
    },
    "known_events_external_knowledge": {
        "warning": "Conocimiento externo NO derivado de los datos; verificar. Coincidir en fechas no prueba causalidad.",
        "events": [
            {"period": "2017-11", "event": "Black Friday (24-nov-2017); el dataset muestra pico de pedidos "
                                            "y de atrasos ese mes"},
            {"period": "2018-02", "event": "Carnaval en Brasil (feb-2018)"},
            {"period": "2018-05", "event": "Huelga de camioneros en Brasil (fines de mayo de 2018)"},
            {"period": "2018-06/07", "event": "Mundial de fútbol 2018"},
        ],
        "data_observation": "Los atrasos altos de feb-mar 2018 no quedan explicados por estos eventos; "
                            "causa no determinada con estos datos.",
    },
}

ANALYSIS_INDEX = {
    "metadata": "filas por tabla y metodología", "dataset_context": "esquema, joins, trampas, definiciones",
    "reproducibility": "versiones y parámetros", "reconciliation": "cuadre de conteos",
    "domains": "valores posibles (categorías, estados, medios de pago) y traducción completa",
    "samples": "filas de ejemplo por tabla", "data_quality": "perfil columna a columna",
    "referential_integrity": "huérfanos y padres sin hijos", "orders": "estados, temporalidad, anomalías",
    "nulls_by_status": "nulos de fechas por estado", "sales": "GMV, ticket, serie mensual (MoM corregido)",
    "delivery": "tiempos, atrasos, por estado/mes, relación con reviews",
    "distance": "distancia vendedor-cliente y su efecto", "freight_model": "qué explica el flete",
    "seller_compliance": "despacho a tiempo del vendedor", "geography": "estados, ciudades, flujos, geolocation",
    "payments": "medios de pago y cuotas", "reviews": "scores, comentarios, palabras y n-gramas",
    "products_and_categories": "ranking, calidad, concentración", "sellers": "concentración y segmentos",
    "customers": "recompra, cohortes, recencia", "basket": "co-compra de categorías y recompra por categoría",
    "rfm": "matriz recencia x valor", "outliers": "pedidos/ítems extremos",
    "cross_dimension_insights": "correlaciones y cruces", "key_findings": "resumen en frases",
}


# ----------------------------------------------------------------------------
# Archivo de contexto compacto
# ----------------------------------------------------------------------------
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


def build_context(out):
    g = lambda *p: dig(out, *p)  # noqa: E731
    monthly = [[m.get("purchase_month") or m.get("index"), m.get("orders"), m.get("revenue"),
                m.get("late_pct"), m.get("avg_review"), m.get("partial_coverage")]
               for m in (g("sales", "monthly") or [])]
    cats = g("products_and_categories", "category_ranking_by_revenue_top25") or []
    states = g("geography", "revenue_by_customer_state") or []
    d_states = g("delivery", "by_customer_state") or []
    sc = g("seller_compliance", "customer_outcomes_by_seller_compliance") or {}
    nulls = lambda t, c: g("data_quality", t, "columns", c, "null_pct")  # noqa: E731
    orphans = {k: v for k, v in (g("referential_integrity", "orphans") or {}).items()
               if isinstance(v, dict) and v.get("orphans")}
    no_children = {k: dig(v, "pct") for k, v in (g("referential_integrity", "parents_without_children") or {}).items()
                   if isinstance(v, dict) and v.get("without_children")}
    ctx = {
        "purpose": "Contexto compacto del dataset Olist para conversaciones futuras. Para el detalle completo "
                   "(perfil por columna, listas, tablas), pedir el JSON completo (ver analysis_index).",
        "usage_instructions": [
            "Responder con las cifras de este archivo; si una cifra no está, decir que hace falta el JSON completo "
            "o los CSV en vez de estimarla.",
            "Respetar definiciones y trampas (dataset_context.definitions / gotchas) al proponer nuevos cálculos.",
            "Los eventos externos son conocimiento no derivado de los datos: citarlos como hipótesis."],
        "metadata": g("metadata"),
        "dataset_context": g("dataset_context"),
        "key_findings": g("key_findings"),
        "data_quality_highlights": {
            "temporal_anomalies": g("orders", "temporal_anomalies"),
            "null_pct": {"orders.order_approved_at": nulls("orders", "order_approved_at"),
                         "orders.order_delivered_carrier_date": nulls("orders", "order_delivered_carrier_date"),
                         "orders.order_delivered_customer_date": nulls("orders", "order_delivered_customer_date"),
                         "reviews.comment_title": nulls("order_reviews", "review_comment_title"),
                         "reviews.comment_message": nulls("order_reviews", "review_comment_message"),
                         "products.category": nulls("products", "product_category_name")},
            "orphans_nonzero": orphans, "parents_without_children_pct": no_children,
            "duplicated_review_ids": g("reviews", "duplicated_review_ids"),
            "orders_with_multiple_reviews": g("reviews", "orders_with_multiple_reviews"),
            "orders_with_review_pct": g("reviews", "orders_with_review_pct"),
            "geolocation": {k: g("geography", "geolocation", k) for k in
                            ("rows", "unique_zip_prefixes", "duplicate_rows", "coords_outside_brazil_bbox",
                             "customer_zips_missing_in_geo_pct", "seller_zips_missing_in_geo_pct")},
            "zero_value_payments": g("payments", "zero_value_payments"),
            "zero_weight_products": g("products_and_categories", "zero_weight_products"),
            "products_without_valid_sales": g("products_and_categories", "products_never_sold"),
            "products_without_valid_sales_note": "Sin ventas en pedidos válidos (excluye canceled/unavailable); no significa que no existan en order_items.",
            "reconciliation": g("reconciliation")},
        "key_metrics": {
            "volume": {
                "orders": g("orders", "total_orders"), "valid_orders": g("orders", "valid_orders"),
                "date_range": g("orders", "date_range"),
                "unique_customers_valid": g("customers", "unique_customers_with_valid_orders"),
                "gmv_items": g("sales", "gmv_items_total"), "freight_total": g("sales", "freight_total"),
                "freight_pct_of_gmv": g("sales", "freight_pct_of_gmv"),
                "avg_item_price": g("sales", "avg_item_price"),
                "order_value_median": g("sales", "order_value_stats", "median"),
                "order_value_mean": g("sales", "order_value_stats", "mean"),
                "yearly": g("sales", "yearly")},
            "status_distribution": g("orders", "status_distribution"),
            "monthly_columns": ["month", "orders", "revenue", "late_pct", "avg_review", "partial_coverage"],
            "monthly": monthly,
            "monthly_notes": {
                "partial_coverage_months": g("sales", "months_with_partial_coverage"),
                "calendar_months_missing": g("sales", "calendar_months_missing_in_range"),
                "median_mom_growth_pct": g("sales", "median_monthly_growth_pct_full_months"),
                "mean_mom_growth_pct": g("sales", "avg_monthly_growth_pct_full_months"),
                "note": "Meses con partial_coverage=true no son comparables (avg_review y late_pct no significativos)."},
            "delivery": {
                "avg_delivery_days": g("delivery", "delivery_days", "mean"),
                "median_delivery_days": g("delivery", "delivery_days", "median"),
                "avg_estimated_days": g("delivery", "estimated_days", "mean"),
                "late_orders_pct": g("delivery", "late_orders_pct"),
                "avg_delay_when_late_days": g("delivery", "avg_delay_when_late_days"),
                "delay_buckets": pick(g("delivery", "delay_buckets"), ["delay_bucket", "pct_orders", "avg_review",
                                                                       "pct_score_1_2"]),
                "worst_late_states": g("delivery", "worst_late_states_top5"),
                "slowest_states": g("delivery", "slowest_states_top5"),
                "fastest_states": g("delivery", "fastest_states_top5"),
                "corr_review": g("delivery", "correlation_review")},
            "reviews": {
                "avg_score": g("reviews", "avg_score"), "distribution": g("reviews", "score_distribution"),
                "pct_with_message": g("reviews", "pct_with_message"),
                "low_score_pct_late_vs_ontime": g("cross_dimension_insights", "low_score_pct_late_vs_ontime"),
                "low_score_pct_by_freight_quartile": g("cross_dimension_insights", "low_score_pct_by_freight_quartile"),
                "top_bigrams_negative": [x.get("ngram") for x in (g("reviews", "top_bigrams_negative_reviews_1_2_stars")
                                                                  or [])[:12]],
                "top_bigrams_positive": [x.get("ngram") for x in (g("reviews", "top_bigrams_positive_reviews_4_5_stars")
                                                                  or [])[:8]]},
            "geography": {
                "top_states_by_revenue": pick(states[:6], ["customer_state", "orders", "revenue_share_pct",
                                                           "avg_freight"]),
                "state_delivery_table_columns": ["state", "orders", "avg_delivery_days", "late_pct", "avg_review"],
                "state_delivery_all": [[s.get("customer_state"), s.get("orders"), s.get("avg_delivery_days"),
                                        s.get("late_pct"), s.get("avg_review")] for s in d_states],
                "cross_state_items_pct": g("geography", "cross_state_items_pct"),
                "avg_distance_km": g("distance", "distance_km_stats", "mean")},
            "distance_and_freight": {
                "spearman_dist_vs": g("distance", "spearman_correlations_order_level", "dist_km"),
                "freight_model_r2": g("freight_model", "r2_full"),
                "freight_r2_single": g("freight_model", "r2_single_feature"),
                "free_shipping_items_pct": g("freight_model", "free_shipping_items_pct")},
            "seller_compliance": {
                "late_to_carrier_pct": g("seller_compliance", "late_to_carrier_pct"),
                "customer_outcomes": {("late_to_carrier" if k == "True" else "on_time_to_carrier"): v
                                      for k, v in sc.items()},
                "sellers_min30_items": g("seller_compliance", "sellers_min30_items")},
            "payments": {
                "by_type": pick(g("payments", "by_type"), ["payment_type", "payments_share_pct",
                                                           "value_share_pct", "avg_installments"]),
                "credit_card_pct_installments_gt1": g("payments", "credit_card_pct_installments_gt1"),
                "payment_vs_items_plus_freight_within_1_cent_pct":
                    g("payments", "payment_vs_items_plus_freight", "pct_within_1_cent")},
            "categories": {
                "n_categories": g("products_and_categories", "n_categories"),
                "top10_by_revenue": pick(cats[:10], ["category", "revenue_share_pct", "avg_price", "avg_review",
                                                     "late_pct"]),
                "worst_rated_min100_orders": pick(g("products_and_categories", "worst_rated_categories_min100_orders"),
                                                  ["category", "orders", "avg_review"])[:5],
                "without_translation": g("products_and_categories", "categories_without_translation"),
                "concentration": g("products_and_categories", "category_concentration")},
            "sellers": {
                "registered": g("sellers", "registered_sellers"), "active": g("sellers", "active_sellers"),
                "concentration": g("sellers", "concentration"),
                "segments": g("sellers", "seller_segments_by_order_volume")},
            "customers": {
                "repeat_customers_pct": g("customers", "repeat_customers_pct"),
                "customers_with_3plus_orders_pct": g("customers", "customers_with_3plus_orders_pct"),
                "median_days_first_to_second": g("customers", "days_between_first_and_second_order", "median"),
                "top20pct_customers_share_of_revenue_pct": g("customers", "top20pct_customers_share_of_revenue_pct"),
                "repeaters_revenue_share_pct": g("rfm", "repeaters_revenue_share_pct"),
                "one_time_buyers_revenue_share_pct": g("rfm", "one_time_buyers_revenue_share_pct")},
            "basket": {
                "multi_category_orders_pct": g("basket", "multi_category_orders_pct"),
                "multi_item_single_category_orders_pct": g("basket", "multi_item_single_category_orders_pct"),
                "top5_category_pairs": (g("basket", "top15_category_pairs") or [])[:5]},
            "outliers": {
                "orders_delivery_over_60_days": g("outliers", "orders_delivery_over_60_days"),
                "items_price_over_p99_pct_of_revenue": g("outliers", "items_price_over_p99_pct_of_revenue")},
        },
        "samples_2_rows": {k: v[:2] for k, v in (g("samples") or {}).items()},
        "analysis_index": ANALYSIS_INDEX,
    }
    return ctx


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Análisis exhaustivo Olist -> JSON completo + JSON de contexto")
    ap.add_argument("--data-dir", required=True, help="Carpeta con los CSV")
    ap.add_argument("--output", default="olist_analysis.json", help="JSON completo")
    ap.add_argument("--context-output", default=None,
                    help="JSON compacto de contexto (por defecto: <output>_context.json)")
    ap.add_argument("--sample-rows", type=int, default=5, help="Filas de ejemplo por tabla en el JSON completo")
    ap.add_argument("--geo-sample", type=int, default=None,
                    help="Muestrear N filas de geolocation (útil si hay poca RAM)")
    args = ap.parse_args()
    ctx_path = args.context_output or re.sub(r"\.json$", "", args.output) + "_context.json"

    D, notes = load(args.data_dir, args.geo_sample)
    required = {"orders", "order_items", "order_payments", "order_reviews", "customers", "sellers", "products"}
    missing = required - set(D)
    if missing:
        sys.exit(f"Faltan tablas obligatorias: {sorted(missing)}")

    od, it, p, rv = build(D)
    it = add_distance(D, it)
    out = {}
    safe("metadata", lambda: sec_metadata(D, notes), out)
    safe("dataset_context", lambda: DATASET_CONTEXT, out)
    safe("reproducibility", lambda: sec_repro(args, D), out)
    safe("reconciliation", lambda: sec_reconciliation(D, od, it), out)
    safe("domains", lambda: sec_domains(D, p), out)
    safe("samples", lambda: sec_samples(D, args.sample_rows), out)
    safe("data_quality", lambda: sec_data_quality(D), out)
    safe("referential_integrity", lambda: sec_integrity(D), out)
    safe("orders", lambda: sec_orders(od), out)
    safe("nulls_by_status", lambda: sec_nulls_by_status(od), out)
    safe("sales", lambda: sec_sales(od, it), out)
    safe("delivery", lambda: sec_delivery(od), out)
    safe("distance", lambda: sec_distance(it), out)
    safe("freight_model", lambda: sec_freight_model(it), out)
    safe("seller_compliance", lambda: sec_seller_compliance(it), out)
    safe("geography", lambda: sec_geography(D, od, it), out)
    safe("payments", lambda: sec_payments(D, od), out)
    safe("reviews", lambda: sec_reviews(D, od, rv), out)
    safe("products_and_categories", lambda: sec_products(D, p, it), out)
    safe("sellers", lambda: sec_sellers(D, it), out)
    safe("customers", lambda: sec_customers(D, od), out)
    safe("basket", lambda: sec_basket(od, it), out)
    safe("rfm", lambda: sec_rfm(od), out)
    safe("outliers", lambda: sec_outliers(od, it), out)
    safe("cross_dimension_insights", lambda: sec_cross_insights(od, it), out)
    out["key_findings"] = sec_findings()

    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(clean(out), fh, ensure_ascii=False, indent=2)
    with open(ctx_path, "w", encoding="utf-8") as fh:
        json.dump(clean(build_context(out), nd=2), fh, ensure_ascii=False, indent=1)
    errors = [k for k, v in out.items() if isinstance(v, dict) and "error" in v]
    print(f"OK completo  -> {args.output} ({os.path.getsize(args.output) / 1e3:.0f} KB)")
    print(f"OK contexto  -> {ctx_path} ({os.path.getsize(ctx_path) / 1e3:.0f} KB)")
    print(f"Secciones con error: {errors or 'ninguna'}")


if __name__ == "__main__":
    main()
