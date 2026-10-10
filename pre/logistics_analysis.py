#!/usr/bin/env python3
"""
Análisis exhaustivo + contexto compacto en JSON del dataset
"Logistics and Supply Chain Dataset" (Kaggle, datasetengineer).

Fuente: https://www.kaggle.com/datasets/datasetengineer/logistics-and-supply-chain-dataset

Uso:
    python logistics_analysis.py --csv ./dynamic_supply_chain_logistics_dataset.csv --output logistics_analysis.json

    --csv puede ser el archivo .csv o la carpeta que lo contiene (toma el primer .csv).
Genera:
    logistics_analysis.json          análisis completo
    logistics_analysis_context.json  contexto compacto para pegar en conversaciones futuras

Opciones:
    --split-date 2023-01-01   corte temporal train/test del modelo base
    --skip-ml                 omite el modelo base (no requiere scikit-learn)
    --sample-rows 5           filas de ejemplo en el JSON completo

Requisitos: pandas, numpy  (opcional: scikit-learn para el modelo base)

Criterios (quedan registrados en el JSON):
  - Todo lo "declarado" proviene del overview de Kaggle; lo "observado" sale de los datos.
  - Los rangos/tipos declarados se contrastan con lo observado (no se asume que se cumplen).
  - Los indicadores de realismo (sintético vs. real) son pistas, no pruebas.
  - El modelo base usa corte temporal (no aleatorio) y excluye los targets como features.
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

SCRIPT_VERSION = "1.1"
DATASET_URL = "https://www.kaggle.com/datasets/datasetengineer/logistics-and-supply-chain-dataset"
EDGE_FRAC = 0.001          # borde (fracción del rango) para detectar saturación en min/max
DECLARED_START, DECLARED_END = pd.Timestamp("2021-01-01"), pd.Timestamp("2024-02-01")  # overview: ene-2021 a ene-2024
SOCAL_BBOX = (32.5, 35.8, -121.0, -114.0)   # lat_min, lat_max, lng_min, lng_max (aprox. Sur de California)
US_BBOX = (24.5, 49.5, -125.0, -66.9)       # EE.UU. contiguo (aprox.)
RISK_ORDER = {"Low Risk": 0, "Moderate Risk": 1, "High Risk": 2}
K = {}  # KPIs para hallazgos automáticos


# ----------------------------------------------------------------------------
# Especificación documentada (overview de Kaggle)
# ----------------------------------------------------------------------------
def S(desc, unit=None, rng=None, kind="continuous", role="feature", group=None):
    return {"description": desc, "unit": unit, "declared_range": rng, "kind": kind, "role": role, "group": group}


SPEC = {
    "timestamp": S("Fecha y hora del registro (resolución horaria)", "datetime", kind="timestamp", group="tiempo"),
    "vehicle_gps_latitude": S("Latitud GPS del vehículo", "grados", group="ubicación"),
    "vehicle_gps_longitude": S("Longitud GPS del vehículo", "grados", group="ubicación"),
    "fuel_consumption_rate": S("Tasa de consumo de combustible", "litros/hora", group="vehículo"),
    "eta_variation_hours": S("Diferencia entre llegada estimada y real", "horas", group="entrega"),
    "traffic_congestion_level": S("Nivel de congestión de tráfico", "escala 0-10", (0, 10), group="entorno"),
    "warehouse_inventory_level": S("Nivel de inventario en bodega", "unidades", group="almacén"),
    "loading_unloading_time": S("Tiempo de carga/descarga", "horas", group="almacén"),
    "handling_equipment_availability": S("Disponibilidad de equipos (0 no, 1 sí)", "0/1", (0, 1), "binary",
                                         group="almacén"),
    "order_fulfillment_status": S("Pedido cumplido a tiempo (0 no, 1 sí)", "0/1", (0, 1), "binary", group="entrega"),
    "weather_condition_severity": S("Severidad del clima", "escala 0-1", (0, 1), group="entorno"),
    "port_congestion_level": S("Congestión del puerto", "escala 0-10", (0, 10), group="entorno"),
    "shipping_costs": S("Costos de envío", "USD", group="costos"),
    "supplier_reliability_score": S("Confiabilidad del proveedor", "escala 0-1", (0, 1), group="proveedor"),
    "lead_time_days": S("Tiempo promedio de entrega del proveedor", "días", group="proveedor"),
    "historical_demand": S("Demanda histórica de servicios logísticos", "unidades", group="almacén"),
    "iot_temperature": S("Temperatura medida por sensores IoT", "°C", group="carga"),
    "cargo_condition_status": S("Condición de la carga por IoT (0 mala, 1 buena)", "0/1", (0, 1), "binary",
                                group="carga"),
    "route_risk_level": S("Nivel de riesgo de la ruta", "escala 0-10", (0, 10), group="entorno"),
    "customs_clearance_time": S("Tiempo de despacho aduanero (unidad no especificada, probablemente horas)",
                                "no especificada", group="entrega"),
    "driver_behavior_score": S("Comportamiento del conductor", "escala 0-1", (0, 1), group="conductor"),
    "fatigue_monitoring_score": S("Nivel de fatiga del conductor", "escala 0-1", (0, 1), group="conductor"),
    "disruption_likelihood_score": S("Probabilidad de disrupción", "escala 0-1", (0, 1), role="target"),
    "delay_probability": S("Probabilidad de retraso del envío", "escala 0-1", (0, 1), role="target"),
    "risk_classification": S("Clasificación de riesgo", "Low/Moderate/High Risk", kind="categorical", role="target"),
    "delivery_time_deviation": S("Desviación del tiempo de entrega vs. esperado", "horas", role="target"),
}
TARGETS_NUM = ["disruption_likelihood_score", "delay_probability", "delivery_time_deviation"]
TARGET_CLS = "risk_classification"
KEY_COLS = ["traffic_congestion_level", "eta_variation_hours", "delay_probability", "disruption_likelihood_score",
            "delivery_time_deviation", "shipping_costs", "fuel_consumption_rate", "weather_condition_severity",
            "port_congestion_level", "route_risk_level"]

# Hipótesis de dominio: (a, b, signo esperado, justificación)
HYPOTHESES = [
    ("traffic_congestion_level", "delay_probability", "+", "más tráfico -> más probabilidad de retraso"),
    ("traffic_congestion_level", "delivery_time_deviation", "+", "más tráfico -> mayor desvío de entrega"),
    ("traffic_congestion_level", "fuel_consumption_rate", "+", "tráfico denso aumenta el consumo"),
    ("traffic_congestion_level", "shipping_costs", "+", "más congestión encarece el envío"),
    ("weather_condition_severity", "delay_probability", "+", "peor clima -> más retraso"),
    ("weather_condition_severity", "disruption_likelihood_score", "+", "peor clima -> más disrupción"),
    ("route_risk_level", "disruption_likelihood_score", "+", "ruta riesgosa -> más disrupción"),
    ("port_congestion_level", "customs_clearance_time", "+", "puerto congestionado -> despacho más lento"),
    ("port_congestion_level", "delay_probability", "+", "congestión portuaria -> retraso"),
    ("fatigue_monitoring_score", "driver_behavior_score", "-", "más fatiga -> peor conducta"),
    ("fatigue_monitoring_score", "delay_probability", "+", "fatiga -> retraso"),
    ("driver_behavior_score", "disruption_likelihood_score", "-", "mejor conducta -> menos disrupción"),
    ("supplier_reliability_score", "lead_time_days", "-", "proveedor confiable -> menor lead time"),
    ("supplier_reliability_score", "delay_probability", "-", "proveedor confiable -> menos retraso"),
    ("handling_equipment_availability", "loading_unloading_time", "-", "más equipos disponibles -> carga más rápida"),
    ("loading_unloading_time", "delivery_time_deviation", "+", "carga lenta -> desvío mayor"),
    ("customs_clearance_time", "delivery_time_deviation", "+", "aduana lenta -> desvío mayor"),
    ("lead_time_days", "delivery_time_deviation", "+", "lead time largo -> desvío mayor"),
    ("historical_demand", "warehouse_inventory_level", "-", "más demanda -> menor inventario"),
    ("order_fulfillment_status", "delay_probability", "-", "pedido cumplido -> menor prob. de retraso"),
    ("eta_variation_hours", "delivery_time_deviation", "+", "ambas miden desvíos temporales"),
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
    return df.reset_index().to_dict("records")


def corr_ratio(x, groups):
    """eta^2: fracción de la varianza de x explicada por los grupos (relación no lineal incluida)."""
    d = pd.DataFrame({"x": np.asarray(x, dtype=float), "g": np.asarray(groups)}).dropna()
    if len(d) < 3:
        return None
    tot = ((d.x - d.x.mean()) ** 2).sum()
    if tot == 0:
        return None
    gm = d.groupby("g").x.agg(["count", "mean"])
    return float((gm["count"] * (gm["mean"] - d.x.mean()) ** 2).sum() / tot)


def haversine(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = np.radians(lat1), np.radians(lat2)
    a = np.sin((p2 - p1) / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin((np.radians(lon2) - np.radians(lon1)) / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def ks_uniform(x):
    x = np.sort(np.asarray(x, dtype=float))
    n = len(x)
    if n < 10 or x[-1] == x[0]:
        return None
    u = (x - x[0]) / (x[-1] - x[0])
    i = np.arange(1, n + 1)
    d = float(max((i / n - u).max(), (u - (i - 1) / n).max()))
    crit = 1.63 / math.sqrt(n)  # ~alfa 0.01
    return {"D": d, "critical_1pct": crit, "approx_uniform": bool(d < crit)}


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


# ----------------------------------------------------------------------------
# Carga y preparación
# ----------------------------------------------------------------------------
def find_csv(path):
    if os.path.isdir(path):
        files = sorted(glob.glob(os.path.join(path, "*.csv")))
        if not files:
            sys.exit(f"No se encontró ningún .csv en {path}")
        return files[0]
    if not os.path.exists(path):
        sys.exit(f"No existe: {path}")
    return path


def load(path):
    notes = []
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]
    missing = [c for c in SPEC if c not in df.columns]
    extra = [c for c in df.columns if c not in SPEC]
    if missing:
        notes.append(f"Columnas documentadas ausentes en el CSV: {missing}")
    if extra:
        notes.append(f"Columnas no documentadas presentes en el CSV: {extra}")
    if "timestamp" in df.columns:
        df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
        bad = int(df["timestamp"].isna().sum())
        if bad:
            notes.append(f"{bad} timestamps no parseables (NaT)")
        df = df.sort_values("timestamp").reset_index(drop=True)
    for c, sp in SPEC.items():
        if c in df.columns and sp["kind"] in ("continuous", "binary"):
            coerced = pd.to_numeric(df[c], errors="coerce")
            lost = int(coerced.isna().sum() - df[c].isna().sum())
            if lost:
                notes.append(f"{c}: {lost} valores no numéricos convertidos a NaN")
            df[c] = coerced
    if TARGET_CLS in df.columns:
        df["_risk_ordinal"] = df[TARGET_CLS].map(RISK_ORDER)
    return df, notes


def numeric_cols(df):
    return [c for c, sp in SPEC.items() if sp["kind"] in ("continuous", "binary") and c in df.columns]


def feature_cols(df):
    return [c for c in numeric_cols(df) if SPEC[c]["role"] == "feature"]


# ----------------------------------------------------------------------------
# Secciones
# ----------------------------------------------------------------------------
def sec_metadata(df, path, notes):
    ts = df["timestamp"] if "timestamp" in df.columns else None
    return {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "file": os.path.basename(path), "file_size_mb": round(os.path.getsize(path) / 1e6, 2),
        "rows": len(df), "cols": len([c for c in df.columns if not c.startswith("_")]),
        "time_range": {"first": ts.min(), "last": ts.max()} if ts is not None else None,
        "notes": notes,
        "methodology": {
            "declared_vs_observed": "lo declarado sale del overview de Kaggle; lo observado, de los datos",
            "realism_indicators": "pistas de si los datos parecen simulados; no son prueba",
            "ml_baseline": "corte temporal; targets excluidos de los features; solo mide señal predictiva",
            "caveats": ["Un solo CSV horario; no hay identificador de vehículo, pedido ni ruta.",
                        "Las filas consecutivas pueden no corresponder a la misma entidad (ver geography y realism)."],
        },
    }


def sec_quality(df, num):
    cols = {}
    for c in [c for c in df.columns if not c.startswith("_")]:
        s = df[c]
        info = {"dtype": str(s.dtype), "nulls": int(s.isna().sum()), "null_pct": round(100 * s.isna().mean(), 3),
                "nunique": int(s.nunique(dropna=True)), "unique_ratio": round(s.nunique(dropna=True) / max(len(s), 1), 4)}
        if c in num:
            info["stats"] = num_stats(s)
            info["is_constant"] = bool(s.nunique(dropna=True) <= 1)
            info["zero_pct"] = 100 * (s == 0).mean()
            info["negative_pct"] = 100 * (s < 0).mean()
            rng = s.max() - s.min()
            if rng and rng > 0:
                edge = EDGE_FRAC * rng
                info["pct_at_min_edge"] = 100 * (s <= s.min() + edge).mean()
                info["pct_at_max_edge"] = 100 * (s >= s.max() - edge).mean()
        elif pd.api.types.is_datetime64_any_dtype(s):
            info["min"], info["max"] = s.min(), s.max()
        elif info["nunique"] <= 40:
            info["top_values"] = value_counts(s, top=15)
        cols[c] = info
    sat = {c: max(i.get("pct_at_min_edge", 0), i.get("pct_at_max_edge", 0)) for c, i in cols.items()
           if "pct_at_min_edge" in i}
    return {"rows": len(df), "memory_mb": round(df.memory_usage(deep=True).sum() / 1e6, 2),
            "duplicate_rows": int(df.drop(columns=[c for c in df.columns if c.startswith("_")]).duplicated().sum()),
            "duplicate_timestamps": int(df["timestamp"].duplicated().sum()) if "timestamp" in df.columns else None,
            "constant_columns": [c for c, i in cols.items() if i.get("is_constant")],
            "columns_edge_saturation_over_2pct": {c: round(v, 2) for c, v in sat.items() if v > 2},
            "columns": cols}


def sec_declared_vs_observed(df):
    res, issues = {}, {"out_of_range": {}, "binary_but_continuous": [], "unexpected_categories": {}}
    for c, sp in SPEC.items():
        if c not in df.columns:
            res[c] = {"present": False}
            continue
        e = {"present": True, "kind_declared": sp["kind"], "declared_range": sp["declared_range"]}
        s = df[c]
        if sp["kind"] == "categorical":
            vc = s.value_counts(dropna=False)
            allowed = list(RISK_ORDER) if c == TARGET_CLS else None
            e["observed_values"] = {str(k): int(v) for k, v in vc.items()}
            if allowed:
                bad = [str(k) for k in vc.index if k not in allowed]
                e["unexpected_values"] = bad
                if bad:
                    issues["unexpected_categories"][c] = bad
        elif sp["kind"] in ("continuous", "binary"):
            e["observed_min"], e["observed_max"] = s.min(), s.max()
            rng = sp["declared_range"]
            if rng:
                below, above = int((s < rng[0]).sum()), int((s > rng[1]).sum())
                e.update({"n_below": below, "n_above": above, "pct_out_of_range": 100 * (below + above) / max(s.notna().sum(), 1)})
                if below + above:
                    issues["out_of_range"][c] = {"declared": list(rng), "observed": [s.min(), s.max()],
                                                 "pct_out": e["pct_out_of_range"]}
            if sp["kind"] == "binary":
                near = ((s - 0).abs() <= 1e-6) | ((s - 1).abs() <= 1e-6)
                e["pct_exactly_0_or_1"] = 100 * near.mean()
                e["n_distinct_values"] = int(s.nunique())
                e["is_truly_binary"] = bool(near.mean() >= 0.99)
                if not e["is_truly_binary"]:
                    issues["binary_but_continuous"].append(c)
        res[c] = e
    K["out_of_range_cols"] = list(issues["out_of_range"])
    K["binary_continuous_cols"] = issues["binary_but_continuous"]
    return {"per_column": res, "issues": issues}


def sec_temporal(df, num):
    ts = df["timestamp"].dropna()
    t = ts.sort_values()
    hour = pd.Timedelta(hours=1)
    full = pd.date_range(t.min().floor("60min"), t.max().floor("60min"), freq=hour)
    present = pd.DatetimeIndex(t.dt.floor("60min").unique())
    missing = full.difference(present)
    d = t.diff()
    big = d[d > hour].sort_values(ascending=False).head(10)
    K["rows_after_declared_end"] = int((t >= DECLARED_END).sum())
    K["last_ts"] = str(t.max())
    K["missing_hours"] = int(len(missing))
    K["expected_hours"] = int(len(full))
    d2 = df.dropna(subset=["timestamp"]).copy()
    d2["hour"], d2["dow"] = d2.timestamp.dt.hour, d2.timestamp.dt.dayofweek
    d2["month"], d2["year"] = d2.timestamp.dt.month, d2.timestamp.dt.year
    d2["ym"] = d2.timestamp.dt.to_period("M").astype(str)
    cal = {}
    for c in num:
        cal[c] = {g: corr_ratio(d2[c], d2[g]) for g in ("hour", "dow", "month", "year")}
    tcodes = d2.timestamp.rank(method="first")
    trend = {c: float(d2[c].corr(tcodes, method="spearman")) for c in num}
    keys = [c for c in KEY_COLS if c in d2.columns]
    out = {
        "first": t.min(), "last": t.max(), "rows": len(df),
        "expected_hourly_rows_in_range": int(len(full)), "missing_hours": int(len(missing)),
        "missing_hours_pct": 100 * len(missing) / max(len(full), 1),
        "duplicate_timestamps": int(ts.duplicated().sum()), "is_sorted_in_file": bool(df["timestamp"].is_monotonic_increasing),
        "pct_gaps_exactly_1h": 100 * (d.dropna() == hour).mean(),
        "largest_gaps": [{"after": str(i), "gap_hours": round(v.total_seconds() / 3600, 1)} for i, v in
                         zip(t.shift(1)[big.index], big)],
        "declared_period": {
            "declared": "2021-01 a 2024-01 (overview)",
            "rows_outside_declared_period": int(((t < DECLARED_START) | (t >= DECLARED_END)).sum()),
            "rows_after_declared_end": int((t >= DECLARED_END).sum()),
            "months_beyond_declared_end": round(max((t.max() - DECLARED_END).days, 0) / 30.44, 1),
            "last_timestamp": t.max()},
        "rows_per_year": d2.year.value_counts().sort_index().to_dict(),
        "rows_per_month": d2.ym.value_counts().sort_index().to_dict(),
        "calendar_effects_eta2": cal,
        "calendar_effects_note": "eta2 ~ fracción de varianza explicada por hora/día/mes/año; cercano a 0 = sin patrón.",
        "trend_spearman_vs_time": trend,
        "means_by_hour": d2.groupby("hour")[keys].mean().round(4).to_dict("index"),
        "means_by_weekday": d2.groupby("dow")[keys].mean().round(4).to_dict("index"),
        "means_by_month_of_year": d2.groupby("month")[keys].mean().round(4).to_dict("index"),
        "means_by_year": d2.groupby("year")[num].mean().round(4).to_dict("index"),
        "monthly_targets": d2.groupby("ym")[[c for c in TARGETS_NUM if c in d2.columns]].mean().round(4).to_dict("index"),
    }
    K["max_calendar_eta2"] = max([v for c in cal.values() for k, v in c.items() if v is not None and k != "year"] or [0])
    return out


def sec_geography(df):
    la, lo = df["vehicle_gps_latitude"], df["vehicle_gps_longitude"]
    inb = lambda b: ((la.between(b[0], b[1])) & (lo.between(b[2], b[3])))  # noqa: E731
    socal, us = inb(SOCAL_BBOX), inb(US_BBOX)
    K["pct_socal"], K["pct_us"] = float(100 * socal.mean()), float(100 * us.mean())
    cells = (la.round(0).astype("Int64").astype(str) + "," + lo.round(0).astype("Int64").astype(str))
    top = cells.value_counts().head(10)
    d = df.dropna(subset=["timestamp", "vehicle_gps_latitude", "vehicle_gps_longitude"]).sort_values("timestamp")
    jump = haversine(d.vehicle_gps_latitude.shift(1), d.vehicle_gps_longitude.shift(1),
                     d.vehicle_gps_latitude, d.vehicle_gps_longitude).dropna()
    K["plausible_track_pct"] = float(100 * (jump <= 120).mean())
    return {
        "lat_stats": num_stats(la), "lng_stats": num_stats(lo),
        "declared_region": "Sur de California (overview)",
        "bbox_southern_california": list(SOCAL_BBOX), "bbox_contiguous_us": list(US_BBOX),
        "pct_inside_southern_california_bbox": 100 * socal.mean(),
        "pct_inside_contiguous_us_bbox": 100 * us.mean(),
        "pct_outside_us_bbox": 100 * (~us).mean(),
        "top10_one_degree_cells": {k: int(v) for k, v in top.items()},
        "n_one_degree_cells": int(cells.nunique()),
        "uniformity_ks": {"latitude": ks_uniform(la.dropna()), "longitude": ks_uniform(lo.dropna())},
        "consecutive_rows_distance_km": num_stats(jump),
        "pct_consecutive_jumps_le_120km": 100 * (jump <= 120).mean(),
        "note": "Si las filas fueran un único vehículo en movimiento horario, se esperarían saltos <= ~120 km. "
                "Saltos grandes y generalizados sugieren que cada fila es una observación independiente.",
    }


def sec_targets(df):
    out = {"numeric_targets": {t: num_stats(df[t]) for t in TARGETS_NUM if t in df.columns}}
    if TARGET_CLS in df.columns:
        vc = df[TARGET_CLS].value_counts(dropna=False)
        K["risk_dist"] = {str(k): round(100 * v / len(df), 1) for k, v in vc.items()}
        out["risk_classification_distribution"] = value_counts(df[TARGET_CLS])
        out["risk_class_imbalance_ratio_max_over_min"] = float(vc.max() / max(vc.min(), 1))
        agg = {}
        for cls, sub in df.groupby(TARGET_CLS):
            agg[str(cls)] = {t: {k: sub[t].agg(k) for k in ("mean", "std", "min", "median", "max")}
                             for t in TARGETS_NUM if t in df.columns}
            agg[str(cls)]["rows"] = len(sub)
        out["numeric_targets_by_risk_class"] = agg
        if "disruption_likelihood_score" in df.columns:
            rng_ = {c: (float(sub["disruption_likelihood_score"].min()), float(sub["disruption_likelihood_score"].max()))
                    for c, sub in df.groupby(TARGET_CLS) if c in RISK_ORDER}
            order = [c for c in RISK_ORDER if c in rng_]
            gaps = [rng_[order[i + 1]][0] - rng_[order[i]][1] for i in range(len(order) - 1)]
            det = bool(len(order) > 1 and all(g_ >= -1e-9 for g_ in gaps))
            K["risk_det"] = det
            out["risk_class_vs_disruption_score"] = {
                "score_range_by_class": {c: list(v) for c, v in rng_.items()},
                "classes_do_not_overlap": det,
                "approx_cut_points": [rng_[order[i]][1] for i in range(len(order) - 1)] if det else None,
                "conclusion": ("risk_classification es una función determinista (por umbrales) de "
                               "disruption_likelihood_score: usar el score como feature sería fuga de información."
                               if det else "Las clases se solapan en disruption_likelihood_score.")}
        if "timestamp" in df.columns:
            ct = pd.crosstab(df.timestamp.dt.year, df[TARGET_CLS], normalize="index") * 100
            out["risk_class_pct_by_year"] = ct.round(2).to_dict("index")
    tn = [t for t in TARGETS_NUM if t in df.columns]
    cols = tn + (["_risk_ordinal"] if "_risk_ordinal" in df.columns else [])
    out["target_correlations_spearman"] = df[cols].corr(method="spearman").rename(
        index={"_risk_ordinal": "risk_ordinal"}, columns={"_risk_ordinal": "risk_ordinal"}).round(3).to_dict("index")
    if "order_fulfillment_status" in df.columns and "delay_probability" in df.columns:
        out["delay_probability_vs_fulfillment"] = {
            "spearman": float(df["order_fulfillment_status"].corr(df["delay_probability"], method="spearman"))}
    return out


def sec_correlations(df, num, feats):
    cols = num + (["_risk_ordinal"] if "_risk_ordinal" in df.columns else [])
    X = df[cols].rename(columns={"_risk_ordinal": "risk_ordinal"})
    pear, spear = X.corr(), X.corr(method="spearman")
    pairs = []
    names = list(spear.columns)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            r = spear.loc[a, b]
            if pd.notna(r):
                pairs.append({"a": a, "b": b, "spearman": r, "pearson": pear.loc[a, b]})
    pairs.sort(key=lambda p: -abs(p["spearman"]))
    # asociación con targets (lineal, monótona y por deciles)
    f2t = {}
    tg = [t for t in TARGETS_NUM if t in df.columns] + (["risk_ordinal"] if "risk_ordinal" in X.columns else [])
    for t in tg:
        rows = []
        for f in feats:
            x = df[f]
            if x.nunique() < 2:
                continue
            q = pd.qcut(x.rank(method="first"), 10, labels=False, duplicates="drop")
            rows.append({"feature": f, "spearman": spear.loc[f, t], "pearson": pear.loc[f, t],
                         "eta2_deciles": corr_ratio(X[t], q)})
        rows.sort(key=lambda r: -abs(r["spearman"] or 0))
        f2t[t] = rows
    # VIF
    vif = None
    try:
        Z = df[feats].dropna()
        Z = Z.loc[:, Z.std() > 0]
        C = np.corrcoef(((Z - Z.mean()) / Z.std()).values.T)
        vif = dict(zip(Z.columns, np.diag(np.linalg.inv(C)).round(3)))
    except Exception as e:  # noqa: BLE001
        vif = {"error": str(e)}
    off = np.abs(spear.loc[feats, feats].values[np.triu_indices(len(feats), 1)])
    K["mean_abs_feature_corr"] = float(np.nanmean(off))
    K["top_corr_pairs"] = pairs[:3]
    return {"spearman_matrix": spear.round(3).to_dict("index"), "pearson_matrix": pear.round(3).to_dict("index"),
            "top25_pairs_by_abs_spearman": pairs[:25],
            "features_vs_targets": f2t,
            "vif_features": vif,
            "mean_abs_feature_feature_spearman": float(np.nanmean(off)),
            "pct_feature_pairs_abs_spearman_lt_0_05": float(100 * np.nanmean(off < 0.05)),
            "features_with_max_abs_spearman_lt_0_05_to_all_targets": [
                f for f in feats if all(abs(next(r["spearman"] for r in f2t[t] if r["feature"] == f)) < 0.05
                                        for t in f2t if any(r["feature"] == f for r in f2t[t]))]}


def sec_hypotheses(df):
    sp = df[numeric_cols(df)].corr(method="spearman")
    rows, cnt = [], {"consistent": 0, "opposite": 0, "no_relationship": 0}
    for a, b, sign, why in HYPOTHESES:
        if a not in sp.columns or b not in sp.columns:
            continue
        r = float(sp.loc[a, b])
        ar = abs(r)
        strength = "ninguna" if ar < 0.05 else "débil" if ar < 0.2 else "moderada" if ar < 0.5 else "fuerte"
        if ar < 0.05:
            verdict = "no_relationship"
        elif (r > 0) == (sign == "+"):
            verdict = "consistent"
        else:
            verdict = "opposite"
        cnt[verdict] += 1
        rows.append({"a": a, "b": b, "expected_sign": sign, "spearman": r, "strength": strength,
                     "verdict": verdict, "rationale": why})
    K["hyp_counts"] = cnt
    K["hyp_total"] = len(rows)
    return {"summary": cnt, "total": len(rows), "threshold_no_relationship_abs_rho": 0.05,
            "interpretation": "En datos operativos reales la mayoría de estas relaciones debería ser al menos débil. "
                              "Muchas 'sin relación' es otra pista de que los datos pueden estar simulados.",
            "checks": rows}


def sec_realism(df, num, feats, corr_info):
    lag1 = {c: float(df[c].autocorr(1)) for c in feats if df[c].nunique() > 1}
    mean_lag = float(np.nanmean(np.abs(list(lag1.values())))) if lag1 else None
    ks_lat = ks_uniform(df["vehicle_gps_latitude"].dropna())
    ks_lng = ks_uniform(df["vehicle_gps_longitude"].dropna())
    flags = {
        "no_temporal_autocorrelation": bool(mean_lag is not None and mean_lag < 0.05),
        "features_nearly_uncorrelated": bool((corr_info.get("pct_feature_pairs_abs_spearman_lt_0_05") or 0) >= 80),
        "gps_uniform_in_box": bool(ks_lat and ks_lng and ks_lat["approx_uniform"] and ks_lng["approx_uniform"]),
        "no_plausible_vehicle_track": bool(K.get("plausible_track_pct", 100) < 10),
    }
    prof = {}
    for c in num:
        x = df[c].dropna()
        r_ = x.max() - x.min()
        if r_ > 0 and x.nunique() > 10:
            prof[c] = ((x - x.min()) / r_).quantile(np.linspace(0.05, 0.95, 19)).values
    names_ = list(prof)
    parent = {c: c for c in names_}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for i_, a_ in enumerate(names_):
        for b_ in names_[i_ + 1:]:
            if float(np.max(np.abs(prof[a_] - prof[b_]))) < 0.02:
                parent[find(a_)] = find(b_)
    groups = {}
    for c in names_:
        groups.setdefault(find(c), []).append(c)
    twin_groups = [v for v in groups.values() if len(v) > 1]
    K["twin_groups"] = twin_groups
    n_true = sum(flags.values())
    K["realism_flags"] = n_true
    K["mean_abs_lag1"] = mean_lag
    edge = {c: max(df[c].pipe(lambda s: 100 * (s <= s.min() + EDGE_FRAC * (s.max() - s.min())).mean()),
                   df[c].pipe(lambda s: 100 * (s >= s.max() - EDGE_FRAC * (s.max() - s.min())).mean()))
            for c in num if df[c].nunique() > 2}
    return {
        "lag1_autocorrelation_by_feature": lag1, "mean_abs_lag1": mean_lag,
        "mean_abs_feature_feature_spearman": corr_info.get("mean_abs_feature_feature_spearman"),
        "gps_uniformity_ks": {"latitude": ks_lat, "longitude": ks_lng},
        "pct_consecutive_gps_jumps_le_120km": K.get("plausible_track_pct"),
        "columns_with_values_piled_at_bounds_pct_gt_2": {c: round(v, 2) for c, v in edge.items() if v > 2},
        "distribution_twin_groups": twin_groups,
        "distribution_twin_note": "Columnas cuya distribución normalizada a [0,1] es casi idéntica (diferencia máxima "
                                  "entre cuantiles < 0.02). Muchas columnas con la misma forma sugieren un mismo generador.",
        "flags": flags, "flags_true": n_true, "flags_total": len(flags),
        "verdict": ("compatible con datos sintéticos/simulados" if n_true >= 3 else
                    "señales mixtas" if n_true == 2 else "sin indicios claros de simulación"),
        "warning": "Indicadores, no prueba. Si el verdict es 'sintéticos', las conclusiones operativas no se "
                   "pueden extrapolar al mundo real; sirve para practicar modelado.",
    }


def sec_ml(df, feats, split_date, skip):
    if skip:
        return {"skipped": "omitido por --skip-ml"}
    try:
        from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor
        from sklearn.inspection import permutation_importance
        from sklearn.metrics import accuracy_score, f1_score, mean_absolute_error, r2_score
    except Exception:
        return {"skipped": "scikit-learn no está instalado (pip install scikit-learn)"}
    d = df.dropna(subset=["timestamp"]).sort_values("timestamp").copy()
    d["hour"], d["dow"], d["month"] = d.timestamp.dt.hour, d.timestamp.dt.dayofweek, d.timestamp.dt.month
    X_cols = feats + ["hour", "dow", "month"]
    cutoff = pd.Timestamp(split_date)
    tr, te = d[d.timestamp < cutoff], d[d.timestamp >= cutoff]
    mode = f"temporal: train < {cutoff.date()} <= test"
    if len(tr) < 200 or len(te) < 200:
        k = int(len(d) * 0.8)
        tr, te = d.iloc[:k], d.iloc[k:]
        mode = "temporal 80/20 (la fecha de corte dejó muy pocas filas)"
    res = {"split": mode, "train_rows": len(tr), "test_rows": len(te), "features_used": X_cols,
           "targets_excluded_from_features": TARGETS_NUM + [TARGET_CLS], "regression": {}, "classification": None}
    rng = np.random.RandomState(0)

    def top_imp(model, Xte, yte, scoring):
        idx = rng.choice(len(Xte), min(len(Xte), 4000), replace=False)
        pi = permutation_importance(model, Xte.iloc[idx], yte.iloc[idx], n_repeats=3, random_state=0, scoring=scoring)
        o = sorted(zip(X_cols, pi.importances_mean), key=lambda x: -x[1])[:10]
        return [{"feature": f, "importance": float(v)} for f, v in o]

    for t in [t for t in TARGETS_NUM if t in d.columns]:
        m = HistGradientBoostingRegressor(max_iter=150, random_state=0).fit(tr[X_cols], tr[t])
        p = m.predict(te[X_cols])
        r2 = float(r2_score(te[t], p))
        res["regression"][t] = {
            "r2_test": r2, "mae_test": float(mean_absolute_error(te[t], p)),
            "mae_baseline_median": float(mean_absolute_error(te[t], np.full(len(te), tr[t].median()))),
            "top10_permutation_importance": top_imp(m, te[X_cols], te[t], "r2"),
            "signal": "sin señal detectable (R² < 0.02)" if r2 < 0.02 else "señal débil" if r2 < 0.2 else
                      "señal moderada" if r2 < 0.5 else "señal fuerte"}
    K["ml_r2"] = {t: v["r2_test"] for t, v in res["regression"].items()}
    if TARGET_CLS in d.columns:
        m = HistGradientBoostingClassifier(max_iter=150, random_state=0).fit(tr[X_cols], tr[TARGET_CLS])
        p = m.predict(te[X_cols])
        maj = tr[TARGET_CLS].value_counts().idxmax()
        acc = float(accuracy_score(te[TARGET_CLS], p))
        res["classification"] = {
            "accuracy_test": acc, "macro_f1_test": float(f1_score(te[TARGET_CLS], p, average="macro")),
            "baseline_majority_class": str(maj),
            "baseline_majority_accuracy": float((te[TARGET_CLS] == maj).mean()),
            "pct_predictions_equal_majority_class": float((p == maj).mean() * 100),
            "top10_permutation_importance": top_imp(m, te[X_cols], te[TARGET_CLS], "accuracy")}
        K["ml_acc"] = acc
        K["ml_acc_base"] = res["classification"]["baseline_majority_accuracy"]
    res["note"] = "Baseline rápido (HistGradientBoosting sin tuning) para medir señal; no es un modelo final."
    return res


def sec_outliers(df, num):
    rules = {}
    flags = pd.Series(0, index=df.index)
    for c, sp in SPEC.items():
        if c in num and sp["declared_range"]:
            lo, hi = sp["declared_range"]
            f = (df[c] < lo) | (df[c] > hi)
            rules[c] = int(f.sum())
            flags += f.astype(int)
    ext = {}
    for c in [c for c in ("shipping_costs", "fuel_consumption_rate", "delivery_time_deviation", "historical_demand",
                          "iot_temperature") if c in df.columns]:
        ext[c] = {"top5_high": records(df.nlargest(5, c)[["timestamp", c]]),
                  "top5_low": records(df.nsmallest(5, c)[["timestamp", c]])}
    return {"rows_with_any_out_of_declared_range": int((flags > 0).sum()),
            "rows_with_2plus_out_of_range": int((flags > 1).sum()),
            "out_of_range_count_by_column": rules, "extreme_values": ext,
            "iqr_outliers_by_column": {c: num_stats(df[c]).get("outliers_iqr") for c in num}}


def sec_samples(df, n):
    d = df.drop(columns=[c for c in df.columns if c.startswith("_")])
    return {"first_rows": d.head(n).to_dict("records"), "random_rows": d.sample(min(n, len(d)), random_state=1)
            .to_dict("records"), "last_rows": d.tail(min(2, len(d))).to_dict("records")}


def sec_repro(args, df):
    return {"script_version": SCRIPT_VERSION, "python": platform.python_version(), "pandas": pd.__version__,
            "numpy": np.__version__, "args": vars(args),
            "parameters": {"EDGE_FRAC": EDGE_FRAC, "SOCAL_BBOX": SOCAL_BBOX, "US_BBOX": US_BBOX,
                           "hypotheses_count": len(HYPOTHESES)}}


def sec_findings(df):
    f, g = [], K.get
    f.append(f"{len(df):,} filas; {g('missing_hours', 0):,} horas faltantes de {g('expected_hours', 0):,} esperadas "
             f"en el rango temporal.")
    if g("rows_after_declared_end"):
        f.append(f"El archivo llega hasta {g('last_ts')[:10]}: {g('rows_after_declared_end'):,} filas posteriores al "
                 f"período declarado (hasta ene-2024).")
    if g("risk_det"):
        f.append("risk_classification es función determinista de disruption_likelihood_score (clases sin solape).")
    if g("twin_groups"):
        f.append("Columnas con distribución casi idéntica: " + "; ".join(", ".join(x) for x in g("twin_groups")) + ".")
    if g("risk_dist"):
        f.append("Distribución de risk_classification: " + ", ".join(f"{k} {v}%" for k, v in g("risk_dist").items()) + ".")
    if g("out_of_range_cols"):
        f.append(f"Columnas con valores fuera del rango documentado: {', '.join(g('out_of_range_cols'))}.")
    if g("binary_continuous_cols"):
        f.append(f"Documentadas como binarias pero con valores continuos: {', '.join(g('binary_continuous_cols'))}.")
    if g("pct_socal") is not None:
        f.append(f"Solo {g('pct_socal'):.1f}% de los registros cae en el bbox del Sur de California; "
                 f"{g('pct_us'):.1f}% en EE.UU. contiguo.")
    if g("hyp_total"):
        c = g("hyp_counts")
        f.append(f"Hipótesis de dominio: {c['consistent']} consistentes, {c['opposite']} opuestas y "
                 f"{c['no_relationship']} sin relación (de {g('hyp_total')}).")
    if g("mean_abs_feature_corr") is not None:
        f.append(f"Correlación media absoluta entre features (Spearman): {g('mean_abs_feature_corr'):.3f}.")
    if g("max_calendar_eta2") is not None:
        f.append(f"Efecto calendario máximo (hora/día/mes): eta² = {g('max_calendar_eta2'):.4f}.")
    if g("ml_r2"):
        f.append("Baseline ML (R² test): " + ", ".join(f"{k} {v:.3f}" for k, v in g("ml_r2").items()) +
                 (f"; accuracy risk_classification {g('ml_acc'):.3f} vs mayoritaria {g('ml_acc_base'):.3f}."
                  if g("ml_acc") is not None else "."))
    if g("realism_flags") is not None:
        f.append(f"Indicadores de simulación: {g('realism_flags')} de 4 presentes.")
    return f


# ----------------------------------------------------------------------------
# Contexto estático
# ----------------------------------------------------------------------------
DATASET_CONTEXT = {
    "name": "Logistics and Supply Chain Dataset",
    "author_on_kaggle": "datasetengineer",
    "source": DATASET_URL,
    "license": "No consta en el overview; verificar en la página de Kaggle.",
    "summary": "Registros horarios (según el overview, ene-2021 a ene-2024; ver temporal.declared_period) de operaciones logísticas: transporte, almacén, "
               "planificación de rutas y monitoreo. Incluye 22 variables de entrada y 4 variables objetivo.",
    "declared_origin": "El overview indica recolección desde GPS, sensores IoT, sistemas de gestión de almacén y "
                       "proveedores externos de datos, en una red logística del Sur de California, con modos camión, "
                       "dron y tren. Los datos se describen como anonimizados y procesados.",
    "declared_use_cases": ["Modelado predictivo de riesgo y disrupciones", "Optimización de rutas y programación",
                           "Mantenimiento predictivo de vehículos", "Impacto del tráfico y clima en la entrega",
                           "Gestión de almacén e inventario"],
    "grain": "1 fila por registro horario; no hay ID de vehículo, pedido, ruta ni modo de transporte.",
    "columns": {c: {k: v for k, v in sp.items()} for c, sp in SPEC.items()},
    "targets": {"regression": TARGETS_NUM, "classification": TARGET_CLS,
                "risk_classes": list(RISK_ORDER)},
    "observed_in_provided_sample": [
        "En un fragmento de 15 filas, las coordenadas abarcan ~30-50°N y ~-70 a -120°O (no solo Sur de California) "
        "y cambian de forma abrupta entre horas consecutivas; el script lo verifica con todo el archivo.",
        "Variables documentadas como 0/1 (handling_equipment_availability, order_fulfillment_status, "
        "cargo_condition_status) aparecen con valores continuos (p. ej. 0.48, 0.76, 0.57).",
        "En la muestra, customs_clearance_time llega a ~4.7 (columna sin escala documentada); "
        "driver_behavior_score se mantiene en 0-1.",
        "Varias columnas muestran valores pegados a un límite (iot_temperature ~ -10, eta_variation_hours ~ 5.0), "
        "lo que sugiere recorte (clipping).",
        "risk_classification es mayoritariamente 'High Risk' en esa muestra."],
    "gotchas": [
        "Verificar rangos y tipos contra declared_vs_observed antes de modelar; el overview no se cumple al pie de la letra.",
        "Los targets pueden depender entre sí (delay_probability, disruption_likelihood_score, risk_classification); "
        "no usarlos como features de otro target salvo que sea intencional.",
        "Usar validación con corte temporal, no aleatoria.",
        "Verificar si risk_classification es función de disruption_likelihood_score (ver "
        "targets.risk_class_vs_disruption_score); si lo es, usar uno como feature del otro es fuga de información.",
        "Verificar el período real contra el declarado (temporal.declared_period).",
        "customs_clearance_time no tiene unidad documentada.",
        "Sin identificador de entidad: no se puede reconstruir trayectorias ni hacer análisis por vehículo/pedido.",
        "Si los indicadores de realismo apuntan a datos simulados, las relaciones 'de negocio' pueden no existir."],
    "definitions": {
        "missing_hours": "horas del rango temporal sin ninguna fila",
        "pct_at_edge": f"% de filas a menos de {EDGE_FRAC * 100:.1f}% del rango respecto del mínimo o máximo observado",
        "eta2": "fracción de varianza explicada por una variable categórica (hora/día/mes/deciles)",
        "hypothesis_verdict": "consistent = signo esperado y |rho|>=0.05; opposite = signo contrario; "
                              "no_relationship = |rho|<0.05",
        "realism_flags": "sin autocorrelación temporal; features casi no correlacionadas; GPS uniforme; "
                         "sin trayectoria plausible de un vehículo"},
}

ANALYSIS_INDEX = {
    "metadata": "tamaño, rango temporal, metodología", "dataset_context": "descripción, columnas, trampas, definiciones",
    "reproducibility": "versiones y parámetros", "samples": "filas de ejemplo",
    "data_quality": "perfil por columna, saturación en límites, duplicados",
    "declared_vs_observed": "rangos/tipos documentados contra lo observado",
    "temporal": "cobertura horaria, huecos, estacionalidad (eta²), tendencia, medias por hora/día/mes/año",
    "geography": "cobertura geográfica vs Sur de California, continuidad de trayectoria",
    "targets": "distribuciones, clases de riesgo y relaciones entre targets",
    "correlations": "matrices Pearson/Spearman, pares top, features vs targets, VIF",
    "hypothesis_checks": "21 hipótesis de dominio contrastadas", "realism_indicators": "pistas de datos simulados",
    "ml_baseline": "señal predictiva con corte temporal", "outliers": "fuera de rango y extremos",
    "key_findings": "resumen en frases"}


# ----------------------------------------------------------------------------
# Contexto compacto
# ----------------------------------------------------------------------------
def build_context(out):
    g = lambda *p: dig(out, *p)  # noqa: E731
    f2t = g("correlations", "features_vs_targets") or {}
    top_feats = {t: pick(rows[:5], ["feature", "spearman", "eta2_deciles"]) for t, rows in f2t.items()}
    hyp = g("hypothesis_checks", "checks") or []
    reg = g("ml_baseline", "regression") or {}
    ctx = {
        "purpose": "Contexto compacto del dataset Logistics and Supply Chain para conversaciones futuras. "
                   "Para el detalle (perfil por columna, matrices, medias por hora/mes), pedir el JSON completo.",
        "usage_instructions": [
            "Responder con las cifras de este archivo; si falta una, decir que hace falta el JSON completo o el CSV.",
            "Distinguir siempre lo documentado (overview) de lo observado (datos).",
            "Tratar las conclusiones operativas con cautela si realism_indicators.verdict apunta a datos simulados."],
        "metadata": g("metadata"), "dataset_context": g("dataset_context"), "key_findings": g("key_findings"),
        "data_quality_highlights": {
            "duplicate_rows": g("data_quality", "duplicate_rows"),
            "duplicate_timestamps": g("data_quality", "duplicate_timestamps"),
            "constant_columns": g("data_quality", "constant_columns"),
            "columns_edge_saturation_over_2pct": g("data_quality", "columns_edge_saturation_over_2pct"),
            "nulls_nonzero": {c: i.get("null_pct") for c, i in (g("data_quality", "columns") or {}).items()
                              if i.get("nulls")},
            "declared_vs_observed_issues": g("declared_vs_observed", "issues"),
            "rows_with_any_out_of_declared_range": g("outliers", "rows_with_any_out_of_declared_range")},
        "key_metrics": {
            "temporal": {k: g("temporal", k) for k in ("first", "last", "expected_hourly_rows_in_range",
                                                        "missing_hours", "missing_hours_pct", "pct_gaps_exactly_1h",
                                                        "duplicate_timestamps", "rows_per_year", "declared_period")},
            "calendar_effects_max_eta2": {c: max([v for k, v in e.items() if v is not None and k != "year"] or [0])
                                          for c, e in (g("temporal", "calendar_effects_eta2") or {}).items()},
            "trend_spearman_vs_time": g("temporal", "trend_spearman_vs_time"),
            "geography": {k: g("geography", k) for k in ("pct_inside_southern_california_bbox",
                                                         "pct_inside_contiguous_us_bbox", "pct_outside_us_bbox",
                                                         "pct_consecutive_jumps_le_120km", "n_one_degree_cells")},
            "feature_stats": {c: {k: i["stats"].get(k) for k in ("mean", "std", "min", "median", "max", "skew")}
                              for c, i in (g("data_quality", "columns") or {}).items() if "stats" in i},
            "targets": {"numeric": {t: {k: s.get(k) for k in ("mean", "std", "min", "median", "max")}
                                    for t, s in (g("targets", "numeric_targets") or {}).items()},
                        "risk_distribution": g("targets", "risk_classification_distribution"),
                        "by_class": g("targets", "numeric_targets_by_risk_class"),
                        "correlations": g("targets", "target_correlations_spearman"),
                        "risk_class_vs_disruption_score": g("targets", "risk_class_vs_disruption_score")},
            "top_features_by_target": top_feats,
            "top_feature_pairs": pick((g("correlations", "top25_pairs_by_abs_spearman") or [])[:5],
                                      ["a", "b", "spearman"]),
            "mean_abs_feature_feature_spearman": g("correlations", "mean_abs_feature_feature_spearman"),
            "hypotheses": {"summary": g("hypothesis_checks", "summary"),
                           "not_consistent": pick([h for h in hyp if h["verdict"] != "consistent"],
                                                  ["a", "b", "expected_sign", "spearman", "verdict"]),
                           "strongest": pick(sorted(hyp, key=lambda h: -abs(h["spearman"]))[:5],
                                             ["a", "b", "spearman", "verdict"])},
            "realism": {k: g("realism_indicators", k) for k in ("flags", "flags_true", "verdict", "mean_abs_lag1",
                                                                 "columns_with_values_piled_at_bounds_pct_gt_2",
                                                                 "distribution_twin_groups")},
            "ml_baseline": {"split": g("ml_baseline", "split") or g("ml_baseline", "skipped"),
                            "regression": {t: {k: v.get(k) for k in ("r2_test", "mae_test", "mae_baseline_median",
                                                                      "signal")} for t, v in reg.items()},
                            "classification": {k: (g("ml_baseline", "classification") or {}).get(k) for k in
                                               ("accuracy_test", "macro_f1_test", "baseline_majority_accuracy",
                                                "pct_predictions_equal_majority_class")},
                            "top_features": {t: [x["feature"] for x in v.get("top10_permutation_importance", [])[:5]]
                                             for t, v in reg.items()}}},
        "samples_2_rows": {"first_rows": (g("samples", "first_rows") or [])[:2],
                           "random_rows": (g("samples", "random_rows") or [])[:2]},
        "analysis_index": ANALYSIS_INDEX}
    return ctx


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Contexto y análisis en JSON: Logistics and Supply Chain Dataset")
    ap.add_argument("--csv", required=True, help="Archivo .csv o carpeta que lo contiene")
    ap.add_argument("--output", default="logistics_analysis.json")
    ap.add_argument("--context-output", default=None, help="Por defecto: <output>_context.json")
    ap.add_argument("--sample-rows", type=int, default=5)
    ap.add_argument("--split-date", default="2023-01-01", help="Corte temporal train/test del modelo base")
    ap.add_argument("--skip-ml", action="store_true", help="Omitir el modelo base")
    args = ap.parse_args()
    ctx_path = args.context_output or re.sub(r"\.json$", "", args.output) + "_context.json"

    path = find_csv(args.csv)
    df, notes = load(path)
    for req in ("timestamp", "vehicle_gps_latitude", "vehicle_gps_longitude"):
        if req not in df.columns:
            sys.exit(f"Falta la columna obligatoria: {req}")
    num, feats = numeric_cols(df), feature_cols(df)

    out = {}
    safe("metadata", lambda: sec_metadata(df, path, notes), out)
    safe("dataset_context", lambda: DATASET_CONTEXT, out)
    safe("reproducibility", lambda: sec_repro(args, df), out)
    safe("samples", lambda: sec_samples(df, args.sample_rows), out)
    safe("data_quality", lambda: sec_quality(df, num), out)
    safe("declared_vs_observed", lambda: sec_declared_vs_observed(df), out)
    safe("temporal", lambda: sec_temporal(df, num), out)
    safe("geography", lambda: sec_geography(df), out)
    safe("targets", lambda: sec_targets(df), out)
    safe("correlations", lambda: sec_correlations(df, num, feats), out)
    safe("hypothesis_checks", lambda: sec_hypotheses(df), out)
    safe("realism_indicators", lambda: sec_realism(df, num, feats, out.get("correlations", {})), out)
    safe("ml_baseline", lambda: sec_ml(df, feats, args.split_date, args.skip_ml), out)
    safe("outliers", lambda: sec_outliers(df, num), out)
    out["key_findings"] = sec_findings(df)

    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(clean(out), fh, ensure_ascii=False, indent=2)
    with open(ctx_path, "w", encoding="utf-8") as fh:
        json.dump(clean(build_context(out), nd=3), fh, ensure_ascii=False, indent=1)
    errors = [k for k, v in out.items() if isinstance(v, dict) and "error" in v]
    print(f"OK completo  -> {args.output} ({os.path.getsize(args.output) / 1e3:.0f} KB)")
    print(f"OK contexto  -> {ctx_path} ({os.path.getsize(ctx_path) / 1e3:.0f} KB)")
    print(f"Secciones con error: {errors or 'ninguna'}")


if __name__ == "__main__":
    main()
