"""
generate_fleet_dataset.py
=========================
Genera las 5 tablas de flota sintética del TPI, acopladas a los datos reales de Olist:

  fleet_vehicles · fleet_drivers · fleet_deliveries (vinculada a Olist por order_id)
  fleet_maintenance · fleet_incidents

Entradas (carpeta --input):
  dynamic_supply_chain_logistics_dataset.csv   Kaggle: distribuciones marginales de las variables simuladas
  olist_orders / olist_customers / olist_sellers / olist_order_items / olist_products / olist_geolocation
                                               Olist: órdenes reales, estados, pesos y coordenadas

Salida (carpeta --output): 5 CSV y fleet_generation_log.txt (parámetros y validación).

Método
------
1. Lo que existe en Olist se DERIVA de datos reales:
   - distance_km          haversine vendedor->cliente (centroides de zip) x factor de ruta (1,15-1,35)
   - delivery_status      'delayed' si Olist entregó después de la fecha prometida
   - eta_variation_hours  horas reales de tránsito menos las esperadas para ese estado de destino
                          y quintil de distancia (mediana del grupo), acotadas a [-168, 336]
2. Lo que NO existe en Olist (tráfico, clima, riesgo de ruta, comportamiento y fatiga del
   conductor, incidentes) se SIMULA con una cópula gaussiana condicionada a señales reales
   (demora, residuo de tránsito, carga mensual, destino, estación, distancia). Las marginales
   son exactamente las empíricas de Kaggle (mapeo por cuantiles); la fuerza de cada vínculo es
   un parámetro explícito (EFFECTS, BEHAVIOR_BETA, FATIGUE_BETA, INCIDENT_COEF).
3. Estructura coherente:
   - 1 conductor por vehículo activo; la licencia habilita el tipo de vehículo; el conductor de la
     entrega maneja el vehículo de la entrega; los vehículos en baja no reciben entregas.
   - hire_date anterior al inicio de Olist; year del vehículo <= 2016.
   - El mantenimiento se genera DESPUÉS de las entregas, a partir de los km acumulados: preventivo
     por km o cada 6 meses; correctivo con hazard creciente en edad, uso y km desde el último
     preventivo. La estacionalidad emerge del volumen de órdenes.
   - Los incidentes tienen probabilidad logística según demora real, tráfico, clima, riesgo,
     edad del vehículo y días desde el último mantenimiento.

Advertencia metodológica
------------------------
Las relaciones entre las variables simuladas y la demora real están impuestas por diseño. Un
hallazgo como "el tráfico aumenta la demora" es una propiedad del simulador, no evidencia
empírica. Además, como se generan condicionadas al resultado, usarlas como predictores equivale
a una fuga de información: tratarlas como covariables operativas simuladas.

Uso
---
    python generate_fleet_dataset.py --input ../raw --output ../fleet_synthetic
"""

import argparse
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import norm, rankdata, spearmanr

warnings.filterwarnings("ignore")

SEED = 42

# ─────────────────────────────────────────────
# PARÁMETROS (todo lo "impuesto" vive acá)
# ─────────────────────────────────────────────
N_VEHICLES = 100
N_BAJA = 5                       # vehículos dados de baja (sin entregas ni conductor)
ASSIGN_BY = "customer_state"     # "customer_state" (reparto) | "seller_state" (origen)
ROAD_FACTOR = (1.15, 1.35)       # distancia por ruta / haversine
DIST_CLIP = (5, 6000)            # km; debe coincidir con el CHECK chk_del_dist del DDL
ETA_CLIP = (-168, 336)           # horas; la variable queda acotada (censurada en los límites)

# pesos de cada señal real en el latente de cada variable (el resto es ruido)
EFFECTS = {
    "traffic": dict(delay=0.25, resid=0.15, load=0.25, urban=0.20),
    "weather": dict(delay=0.25, resid=0.10, season=0.40),
    "risk":    dict(delay=0.30, dist=0.25, remote=0.20),
}
BEHAVIOR_BETA = 0.4              # sesgo: pedidos tardíos tienden a caer en conductores de bajo score
FATIGUE_BETA = 0.5               # ... y de alta fatiga
INCIDENT_RATE = 0.037            # fracción de entregas con incidente
INCIDENT_COEF = dict(late=1.6, traffic=0.35, weather=0.30, risk=0.25, age=0.20, maint=0.25)

MACRO = {
    "SP": "SE", "RJ": "SE", "MG": "SE", "ES": "SE",
    "PR": "S", "SC": "S", "RS": "S",
    "BA": "NE", "SE": "NE", "AL": "NE", "PE": "NE", "PB": "NE", "RN": "NE",
    "CE": "NE", "PI": "NE", "MA": "NE",
    "GO": "CO", "MT": "CO", "MS": "CO", "DF": "CO",
    "AM": "N", "PA": "N", "AC": "N", "RO": "N", "RR": "N", "AP": "N", "TO": "N",
}
URBAN = {"SP": 1.0, "RJ": 1.0, "DF": 0.8, "MG": 0.6, "PR": 0.5, "RS": 0.5, "BA": 0.5,
         "PE": 0.5, "CE": 0.5, "SC": 0.4, "GO": 0.4, "ES": 0.4}          # default 0.2
REMOTE = {"N": 1.0, "NE": 0.6, "CO": 0.5, "S": 0.2, "SE": 0.0}
RAINY = {"SE": {11, 12, 1, 2, 3}, "S": {10, 11, 12, 1, 2}, "CO": {11, 12, 1, 2, 3},
         "NE": {4, 5, 6, 7}, "N": {12, 1, 2, 3, 4, 5}}
SERVICE_INTERVAL_KM = {"moto": 5000, "van": 10000, "truck": 15000}
CORR_BASE_HAZARD = 0.04          # prob. mensual de correctivo para un vehículo promedio
CORR_MAX_HAZARD = 0.20           # tope mensual
INCIDENT_TYPES = ["averia", "accidente", "retraso_trafico", "condicion_climatica", "falla_mecanica_menor"]
INCIDENT_BASE_P = np.array([0.20, 0.05, 0.40, 0.25, 0.10])

rng = np.random.default_rng(SEED)


# ─────────────────────────────────────────────
# UTILIDADES
# ─────────────────────────────────────────────
def rn(x):
    """Rank-normal: ranking -> cuantiles de N(0,1). Ignora la escala original."""
    x = np.asarray(x, float)
    return norm.ppf(rankdata(x, method="average") / (len(x) + 1))


def zs(x):
    x = np.asarray(x, float)
    return (x - np.nanmean(x)) / (np.nanstd(x) + 1e-12)


def to_marginal(latent, reference):
    """Mapea un latente a la distribución empírica de `reference` (copula gaussiana)."""
    u = rankdata(latent, method="average") / (len(latent) + 1)
    return np.quantile(reference.dropna().values, u)


def latent(parts, weights):
    """Combinación lineal de señales estandarizadas + ruido de varianza residual."""
    s = sum(w * p for w, p in zip(weights, parts))
    resid = max(1.0 - sum(w * w for w in weights), 0.10)
    return s + rng.normal(0, np.sqrt(resid), len(s))


def haversine(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dphi, dl = p2 - p1, np.radians(lon2 - lon1)
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def sigmoid(x):
    return 1 / (1 + np.exp(-x))


# ─────────────────────────────────────────────
# 1. CARGA Y TABLA BASE DE ÓRDENES (señales reales)
# ─────────────────────────────────────────────
def load_base(inp: Path):
    print("▶ Cargando fuentes...")
    kag = pd.read_csv(inp / "dynamic_supply_chain_logistics_dataset.csv")
    date_cols = ["order_purchase_timestamp", "order_delivered_carrier_date",
                 "order_delivered_customer_date", "order_estimated_delivery_date"]
    orders = pd.read_csv(inp / "olist_orders_dataset.csv", parse_dates=date_cols)
    customers = pd.read_csv(inp / "olist_customers_dataset.csv")
    sellers = pd.read_csv(inp / "olist_sellers_dataset.csv")
    items = pd.read_csv(inp / "olist_order_items_dataset.csv")
    products = pd.read_csv(inp / "olist_products_dataset.csv")
    geo = pd.read_csv(inp / "olist_geolocation_dataset.csv")

    # Geografía: bounding box de Brasil -> centroide (mediana) por zip y por estado
    geo = geo[geo.geolocation_lat.between(-34, 6) & geo.geolocation_lng.between(-74, -34)]
    zip_c = geo.groupby("geolocation_zip_code_prefix")[["geolocation_lat", "geolocation_lng"]].median()
    st_c = geo.groupby("geolocation_state")[["geolocation_lat", "geolocation_lng"]].median()

    d = orders[orders.order_status == "delivered"].dropna(
        subset=["order_purchase_timestamp", "order_delivered_customer_date"]).copy()
    d = d.merge(customers[["customer_id", "customer_state", "customer_zip_code_prefix"]], on="customer_id", how="left")

    first = items.sort_values(["order_id", "order_item_id"]).drop_duplicates("order_id")[["order_id", "seller_id", "product_id"]]
    first = first.merge(sellers[["seller_id", "seller_state", "seller_zip_code_prefix"]], on="seller_id", how="left")
    first = first.merge(products[["product_id", "product_weight_g"]], on="product_id", how="left")
    d = d.merge(first[["order_id", "seller_state", "seller_zip_code_prefix", "product_weight_g"]], on="order_id", how="left")

    w = d.product_weight_g.where(d.product_weight_g > 0)
    d["product_weight_g"] = w.fillna(w.median())
    d["seller_state"] = d.seller_state.fillna("SP")

    # Coordenadas con fallback al centroide del estado
    for pref, st, zc in [("c", "customer_state", "customer_zip_code_prefix"), ("s", "seller_state", "seller_zip_code_prefix")]:
        d[f"{pref}_lat"] = d[zc].map(zip_c.geolocation_lat)
        d[f"{pref}_lng"] = d[zc].map(zip_c.geolocation_lng)
        miss = d[f"{pref}_lat"].isna()
        d.loc[miss, f"{pref}_lat"] = d.loc[miss, st].map(st_c.geolocation_lat)
        d.loc[miss, f"{pref}_lng"] = d.loc[miss, st].map(st_c.geolocation_lng)
    d["hav_km"] = haversine(d.s_lat, d.s_lng, d.c_lat, d.c_lng)
    d["hav_km"] = d.hav_km.fillna(d.hav_km.median())
    d = d.reset_index(drop=True)
    print(f"  Órdenes entregadas con fecha de entrega: {len(d):,}")
    return kag, d


def real_signals(d: pd.DataFrame):
    """Señales reales estandarizadas que alimentan los latentes."""
    purchase, est = d.order_purchase_timestamp, d.order_estimated_delivery_date
    carrier, cust = d.order_delivered_carrier_date, d.order_delivered_customer_date

    d["delay_days"] = (cust - est).dt.total_seconds() / 86400
    d["late"] = (d.delay_days > 0).astype(int)

    # Tránsito: carrier->cliente (si falta, compra->cliente). Piso en 0.
    transit = (cust - carrier).dt.total_seconds() / 86400
    transit = transit.fillna((cust - purchase).dt.total_seconds() / 86400).clip(lower=0.05)
    d["transit_days"] = transit

    d["hav_bucket"] = pd.qcut(d.hav_km, 5, labels=False, duplicates="drop")
    expected = d.groupby(["customer_state", "hav_bucket"]).transit_days.transform("median")
    d["eta_variation_hours"] = ((d.transit_days - expected) * 24).clip(*ETA_CLIP).round(2)
    d["resid_z"] = zs(np.log1p(d.transit_days) - np.log1p(expected))

    month = d.order_purchase_timestamp.dt.to_period("M")
    vol = month.map(month.value_counts())
    d["load_z"] = zs(vol.astype(float))

    d["macro"] = d.customer_state.map(MACRO).fillna("SE")
    d["urban_z"] = zs(d.customer_state.map(URBAN).fillna(0.2))
    d["remote_z"] = zs(d.macro.map(REMOTE))
    m = d.order_purchase_timestamp.dt.month
    d["season_z"] = zs([1.0 if mm in RAINY[mc] else 0.0 for mm, mc in zip(m, d.macro)])
    d["dist_z"] = zs(np.log1p(d.hav_km))
    # señal de demora: parte continua + parte binaria
    d["delay_z"] = zs(0.6 * rn(d.delay_days) + 0.6 * zs(d.late))
    return d


# ─────────────────────────────────────────────
# 2. FLOTA: vehículos + conductores (1:1, licencia coherente)
# ─────────────────────────────────────────────
def allocate_counts(demand: pd.Series, n: int, k_guarantee: int):
    target = demand / demand.sum() * n
    cnt = np.floor(target).astype(int)
    left = n - cnt.sum()
    cnt[(target - cnt).sort_values(ascending=False).index[:left]] += 1
    for st in demand.sort_values(ascending=False).index[:k_guarantee]:
        if cnt[st] == 0:
            cnt[cnt.idxmax()] -= 1
            cnt[st] = 1
    return cnt[cnt > 0]


def build_fleet(d, kag):
    print("\n▶ Generando fleet_vehicles y fleet_drivers...")
    d["vtype"] = np.select([d.product_weight_g < 300, d.product_weight_g < 2000], ["moto", "van"], "truck")
    d["assign_state"] = d[ASSIGN_BY].fillna("SP")

    n_active = N_VEHICLES - N_BAJA
    share = d.vtype.value_counts(normalize=True)
    n_type = {t: max(12, int(round(n_active * share[t]))) for t in ["moto", "van", "truck"]}
    n_type["van"] += n_active - sum(n_type.values())          # ajuste a n_active

    brands = {"moto": ["Honda", "Yamaha", "Suzuki"], "van": ["Fiat", "Ford", "Volkswagen", "Renault"],
              "truck": ["Mercedes-Benz", "Scania", "Volvo", "Ford Cargo"]}
    models = {"moto": ["CG 160", "Factor 150", "Burgman 125"], "van": ["Ducato", "Transit", "Kombi", "Master"],
              "truck": ["Accelo 1016", "P 310", "VM 270", "Cargo 1119"]}
    capacity = {"moto": 30, "van": 500, "truck": 5000}
    fscale = {"moto": 0.4, "van": 0.8, "truck": 1.4}
    fuel_ref = kag.fuel_consumption_rate.dropna()

    def fuel(vt):
        if vt == "truck":
            return rng.choice(["diesel", "diesel_b10"], p=[0.7, 0.3])
        if vt == "van":
            return rng.choice(["flex", "diesel", "gas_natural"], p=[0.5, 0.3, 0.2])
        return rng.choice(["flex", "gasolina"], p=[0.7, 0.3])

    slots = []                                              # (type, base_state, status)
    for vt, n in n_type.items():
        dem = d[d.vtype == vt].assign_state.value_counts()
        for st, c in allocate_counts(dem, n, k_guarantee=min(10, n // 2)).items():
            slots += [(vt, st, "activo")] * int(c)
    baja_types = rng.choice(["moto", "van", "truck"], N_BAJA, p=[0.4, 0.4, 0.2])
    slots += [(vt, rng.choice(list(MACRO)), "baja") for vt in baja_types]

    letters = list("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    seen_plates = set()

    def new_plate():
        while True:
            pl = "".join(rng.choice(letters, 3)) + f"-{rng.integers(1000, 9999)}"
            if pl not in seen_plates:
                seen_plates.add(pl)
                return pl

    veh_rows = []
    for i, (vt, st, status) in enumerate(slots, start=1):
        veh_rows.append(dict(
            vehicle_id=i,
            plate=new_plate(),
            type=vt, brand=rng.choice(brands[vt]), model=rng.choice(models[vt]),
            year=int(rng.integers(2010, 2017)),             # <= 2016: en servicio durante todo el período
            capacity_kg=capacity[vt], fuel_type=fuel(vt),
            fuel_consumption_rate_lh=round(float(max(1.0, np.quantile(fuel_ref, rng.random()) * fscale[vt])), 2),
            status=status, _base_state=st))
    veh = pd.DataFrame(veh_rows)

    # Conductores: 1 por vehículo activo, licencia = tipo de vehículo
    lic = {"moto": "A", "van": "B", "truck": "E"}
    first = ["Carlos", "João", "Pedro", "Lucas", "Marcos", "Rafael", "André", "Felipe", "Rodrigo", "Bruno",
             "Fernando", "Diego", "Eduardo", "Thiago", "Gustavo", "Gabriel", "Mateus", "Igor", "Leandro",
             "Alessandro", "Maria", "Ana", "Julia", "Camila", "Patricia", "Sandra", "Lucia", "Renata",
             "Claudia", "Beatriz"]
    last = ["Silva", "Santos", "Oliveira", "Souza", "Lima", "Ferreira", "Costa", "Rodrigues", "Alves",
            "Nascimento", "Pereira", "Carvalho", "Melo", "Barbosa", "Ribeiro", "Martins", "Rocha", "Gomes",
            "Araújo", "Cavalcanti"]
    act = veh[veh.status == "activo"].reset_index(drop=True)
    beh = np.clip(to_marginal(rng.normal(size=len(act)), kag.driver_behavior_score), 0, 1)
    fat = np.clip(to_marginal(rng.normal(size=len(act)), kag.fatigue_monitoring_score), 0, 1)
    drv_rows = []
    for j, v in act.iterrows():
        y = int(rng.integers(2010, 2017))
        mth = int(rng.integers(1, 9 if y == 2016 else 13))   # contratado antes del inicio de Olist (2016-09)
        drv_rows.append(dict(
            driver_id=j + 1, name=f"{rng.choice(first)} {rng.choice(last)}",
            license_type=lic[v.type], hire_date=f"{y}-{mth:02d}-{int(rng.integers(1, 28)):02d}",
            region_assigned=v._base_state, vehicle_id=int(v.vehicle_id),
            driver_behavior_score=round(float(beh[j]), 4), fatigue_score_avg=round(float(fat[j]), 4),
            _vtype=v.type))
    drv = pd.DataFrame(drv_rows)
    print(f"  {len(veh)} vehículos ({N_BAJA} de baja) · {len(drv)} conductores (1:1 con vehículos activos)")
    return veh, drv


# ─────────────────────────────────────────────
# 3. ASIGNACIÓN DE CONDUCTOR/VEHÍCULO A CADA ENTREGA
# ─────────────────────────────────────────────
def assign_drivers(d, drv):
    print("\n▶ Asignando conductor y vehículo a cada entrega...")
    bz, fz = zs(drv.driver_behavior_score.values), zs(drv.fatigue_score_avg.values)
    w_late = np.exp(-BEHAVIOR_BETA * bz + FATIGUE_BETA * fz)
    w_ok = np.exp(0.25 * (BEHAVIOR_BETA * bz - FATIGUE_BETA * fz))

    by_state = {k: g.index.values for k, g in drv.groupby(["region_assigned", "_vtype"])}
    drv["_macro"] = drv.region_assigned.map(MACRO)
    by_macro = {k: g.index.values for k, g in drv.groupby(["_macro", "_vtype"])}
    by_type = {k: g.index.values for k, g in drv.groupby("_vtype")}

    def pool(st, vt):
        if (st, vt) in by_state:
            return by_state[(st, vt)]
        return by_macro.get((MACRO.get(st, "SE"), vt), by_type[vt])

    chosen = np.empty(len(d), dtype=int)
    for (st, vt), idx in d.groupby(["assign_state", "vtype"]).groups.items():
        p = pool(st, vt)
        idx = np.asarray(idx)
        late = d.late.values[idx] == 1
        for mask, w in [(late, w_late), (~late, w_ok)]:
            if mask.any():
                pr = w[p] / w[p].sum()
                chosen[idx[mask]] = rng.choice(p, size=mask.sum(), p=pr)
    d["driver_id"] = drv.driver_id.values[chosen]
    d["vehicle_id"] = drv.vehicle_id.values[chosen]
    return d


# ─────────────────────────────────────────────
# 4. VARIABLES OPERATIVAS (copula condicionada)
# ─────────────────────────────────────────────
def operational_vars(d, kag):
    print("\n▶ Generando variables operativas condicionadas a señales reales...")
    E = EFFECTS
    d["traffic_congestion_level"] = np.clip(to_marginal(latent(
        [d.delay_z, d.resid_z, d.load_z, d.urban_z],
        [E["traffic"][k] for k in ("delay", "resid", "load", "urban")]), kag.traffic_congestion_level), 0, 10).round(2)
    d["weather_condition_severity"] = np.clip(to_marginal(latent(
        [d.delay_z, d.resid_z, d.season_z],
        [E["weather"][k] for k in ("delay", "resid", "season")]), kag.weather_condition_severity), 0, 1).round(3)
    d["route_risk_level"] = np.clip(to_marginal(latent(
        [d.delay_z, d.dist_z, d.remote_z],
        [E["risk"][k] for k in ("delay", "dist", "remote")]), kag.route_risk_level), 0, 10).round(2)

    tf = {"moto": 0.6, "van": 1.0, "truck": 1.6}
    lt = to_marginal(latent([zs(rn(d.product_weight_g))], [0.5]), kag.loading_unloading_time)
    d["loading_unloading_time_h"] = np.clip(lt * d.vtype.map(tf).values, 0.1, 8).round(2)

    road = rng.uniform(*ROAD_FACTOR, len(d))
    d["distance_km"] = np.clip(d.hav_km * road, *DIST_CLIP).round(1)
    d["delivery_status"] = np.where(d.late == 1, "delayed", "on_time")
    d["route_state"] = d.seller_state
    return d


# ─────────────────────────────────────────────
# 5. MANTENIMIENTO (a partir del uso real)
# ─────────────────────────────────────────────
def build_maintenance(d, veh):
    print("\n▶ Generando fleet_maintenance a partir del uso...")
    d["km_share"] = np.clip(20 + 0.04 * d.distance_km, 20, 150)
    d["ym"] = d.order_purchase_timestamp.dt.to_period("M")
    usage = d.groupby(["vehicle_id", "ym"]).km_share.sum()
    months = pd.period_range("2016-09", "2018-10", freq="M")
    type_mean = d.groupby("vtype").km_share.sum().div(
        veh[veh.status == "activo"].groupby("type").size()).div(len(months))

    comps = {"preventivo": ["aceite_motor", "filtro_aire", "filtro_combustible", "revision_frenos",
                            "neumaticos", "bateria", "correa_distribucion"],
             "correctivo": ["motor", "transmision", "sistema_electrico", "frenos", "suspension",
                            "escape", "inyectores", "caja_cambios"]}
    cost = {"moto": {"preventivo": (80, 250), "correctivo": (200, 1200)},
            "van": {"preventivo": (150, 500), "correctivo": (400, 3000)},
            "truck": {"preventivo": (300, 900), "correctivo": (800, 8000)}}

    rows = []
    for _, v in veh.iterrows():
        vt, vid = v.type, v.vehicle_id
        last_m = months[-1] if v.status == "activo" else months[int(rng.integers(3, 12))]
        odo = max(2000, (2016 - v.year) * rng.uniform(8000, 15000))
        last_prev_odo, last_prev_date = odo, pd.Timestamp("2016-09-01")
        for m in months:
            if m > last_m:
                break
            km = float(usage.get((vid, m), type_mean.get(vt, 1000)))
            odo += km
            age = m.year - v.year
            day = int(rng.integers(1, 28))
            dt = pd.Timestamp(year=m.year, month=m.month, day=day)
            events = []
            if odo - last_prev_odo >= SERVICE_INTERVAL_KM[vt] or (dt - last_prev_date).days >= 183:
                events.append("preventivo")
                last_prev_odo, last_prev_date = odo, dt
            h = CORR_BASE_HAZARD * (1 + 0.15 * age) * (km / type_mean.get(vt, km + 1e-9)) ** 0.8 \
                * (1 + (odo - last_prev_odo) / SERVICE_INTERVAL_KM[vt])
            if rng.random() < min(h, CORR_MAX_HAZARD):
                events.append("correctivo")
            for mt in events:
                lo, hi = cost[vt][mt]
                down = rng.uniform(4, 48) * (1 + 0.05 * age) if mt == "correctivo" else rng.uniform(1, 6)
                rows.append(dict(vehicle_id=vid, date=dt.strftime("%Y-%m-%d"), type=mt,
                                 component=rng.choice(comps[mt]), cost_brl=round(float(rng.uniform(lo, hi)), 2),
                                 downtime_hours=round(float(down), 1), mileage_at_service=int(odo)))
    mt = pd.DataFrame(rows).sort_values(["date", "vehicle_id"]).reset_index(drop=True)
    mt.insert(0, "maintenance_id", range(1, len(mt) + 1))
    print(f"  {len(mt):,} registros ({(mt.type == 'correctivo').sum()} correctivos)")
    return mt


# ─────────────────────────────────────────────
# 6. INCIDENTES
# ─────────────────────────────────────────────
def build_incidents(d, veh, mt, kag):
    print("\n▶ Generando fleet_incidents...")
    ref = d.order_delivered_carrier_date.where(
        d.order_delivered_carrier_date.between(d.order_purchase_timestamp, d.order_delivered_customer_date),
        d.order_purchase_timestamp)
    left = pd.DataFrame({"i": np.arange(len(d)), "vehicle_id": d.vehicle_id.values,
                         "ref": pd.to_datetime(ref.values).astype("datetime64[ns]")}).sort_values("ref")
    m = pd.merge_asof(left, mt[["vehicle_id", "date"]].assign(date=lambda x: pd.to_datetime(x.date).astype("datetime64[ns]")).sort_values("date"),
                      left_on="ref", right_on="date", by="vehicle_id", direction="backward").sort_values("i")
    since = (m.ref - m.date).dt.days.fillna(365).values
    age = (d.order_purchase_timestamp.dt.year.values - d.vehicle_id.map(veh.set_index("vehicle_id").year).values)

    zt, zw, zr = zs(d.traffic_congestion_level), zs(d.weather_condition_severity), zs(d.route_risk_level)
    za, zm = zs(age), zs(np.log1p(since))
    C = INCIDENT_COEF
    s = C["late"] * d.late.values + C["traffic"] * zt + C["weather"] * zw + C["risk"] * zr + C["age"] * za + C["maint"] * zm

    target = INCIDENT_RATE * len(d)
    lo, hi = -15.0, 5.0
    for _ in range(60):                                       # bisección del intercepto
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if sigmoid(mid + s).sum() < target else (lo, mid)
    hit = np.flatnonzero(rng.random(len(d)) < sigmoid(mid + s))

    base = np.log(INCIDENT_BASE_P)
    adj = np.column_stack([0.6 * zm + 0.4 * za, 0.4 * zr + 0.3 * zt, 0.8 * zt, 0.8 * zw, 0.3 * za + 0.3 * zm])[hit]
    lg = base + adj
    pr = np.exp(lg - lg.max(1, keepdims=True))
    pr /= pr.sum(1, keepdims=True)
    tcode = (rng.random(len(hit))[:, None] > pr.cumsum(1)).sum(1).clip(0, 4)
    rngs = [(4, 24), (8, 48), (1, 6), (2, 12), (1, 4)]
    impact = np.array([rng.uniform(*rngs[t]) for t in tcode])
    impact = np.where(d.late.values[hit] == 1, impact, np.maximum(0.5, impact * 0.5)).round(1)

    t0 = ref.values[hit].astype("datetime64[D]").astype(np.int64)
    t1 = d.order_delivered_customer_date.values[hit].astype("datetime64[D]").astype(np.int64)
    day = t0 + (rng.random(len(hit)) * (np.maximum(t1 - t0, 0) + 1)).astype(np.int64).clip(max=None)
    day = np.minimum(day, t1)
    out = pd.DataFrame({
        "incident_id": np.arange(1, len(hit) + 1),
        "vehicle_id": d.vehicle_id.values[hit],
        "date": pd.to_datetime(day.astype("datetime64[D]")).strftime("%Y-%m-%d"),
        "type": np.array(INCIDENT_TYPES)[tcode],
        "disruption_likelihood": np.round(np.clip(to_marginal(
            latent([zs(impact)], [0.5]), kag.disruption_likelihood_score), 0, 1), 4),
        "impact_on_delivery_h": impact,
        "order_id": d.order_id.values[hit]})
    late_cov = d.late.values[hit].sum() / max(d.late.sum(), 1)
    print(f"  {len(out):,} incidentes · cobertura de órdenes tardías: {late_cov:.1%}")
    return out


# ─────────────────────────────────────────────
# 7. VALIDACIÓN
# ─────────────────────────────────────────────
def validate(d, veh, drv, mt, inc, kag, log):
    def out(msg=""):
        print(msg)
        log.append(msg)

    out("\n" + "=" * 60 + "\nVALIDACIÓN\n" + "=" * 60)
    out("1) Dependencia con la realidad (Spearman vs delay_days / eta_variation_hours)")
    for c in ["traffic_congestion_level", "weather_condition_severity", "route_risk_level", "loading_unloading_time_h"]:
        out(f"   {c:<28} vs demora real {spearmanr(d[c], d.delay_days)[0]:+.3f} | "
            f"vs eta_var {spearmanr(d[c], d.eta_variation_hours)[0]:+.3f}")
    out(f"   distance_km vs haversine     {spearmanr(d.distance_km, d.hav_km)[0]:+.3f}")
    dd = drv.assign(late_rate=d.groupby("driver_id").late.mean().reindex(drv.driver_id).values,
                    n=d.groupby("driver_id").size().reindex(drv.driver_id).values)
    dd = dd[dd.n >= 30]
    out(f"   behavior_score vs tasa demora (conductor, n={len(dd)}): {spearmanr(dd.driver_behavior_score, dd.late_rate)[0]:+.3f}")
    out(f"   fatigue_score  vs tasa demora (conductor)            : {spearmanr(dd.fatigue_score_avg, dd.late_rate)[0]:+.3f}")
    out("\n2) Marginales vs Kaggle (media / desvío)")
    for c, k in [("traffic_congestion_level", "traffic_congestion_level"), ("weather_condition_severity", "weather_condition_severity"),
                 ("route_risk_level", "route_risk_level")]:
        out(f"   {c:<28} sint {d[c].mean():.2f}/{d[c].std():.2f}   kaggle {kag[k].mean():.2f}/{kag[k].std():.2f}")
    out("\n3) Coherencia estructural")
    dv = d.merge(veh[["vehicle_id", "type", "status"]], on="vehicle_id").merge(drv[["driver_id", "license_type", "vehicle_id"]], on="driver_id", suffixes=("", "_drv"))
    lic = {"moto": "A", "van": "B", "truck": "E"}
    out(f"   conductor maneja el vehículo de la entrega : {(dv.vehicle_id == dv.vehicle_id_drv).mean():.1%}")
    out(f"   licencia habilita el vehículo              : {(dv.license_type == dv.type.map(lic)).mean():.1%}")
    out(f"   entregas con vehículo en baja              : {(dv.status == 'baja').sum()}")
    first_del = d.groupby("driver_id").order_purchase_timestamp.min()
    hd = pd.to_datetime(drv.set_index("driver_id").hire_date)
    out(f"   conductores contratados tras su 1ª entrega  : {(hd > first_del.reindex(hd.index)).sum()}")
    mv = mt.merge(veh[["vehicle_id", "year"]], on="vehicle_id")
    out(f"   mantenimientos antes del año del vehículo  : {(pd.to_datetime(mv.date).dt.year < mv.year).sum()}")
    out(f"   estado: {d.delivery_status.value_counts(normalize=True).round(3).to_dict()}")
    out(f"   distance_km [{d.distance_km.min():.1f}, {d.distance_km.max():.1f}] · eta_variation_hours "
        f"[{d.eta_variation_hours.min():.1f}, {d.eta_variation_hours.max():.1f}]")
    mm = d.groupby(d.order_purchase_timestamp.dt.to_period("M")).size()
    cc = mt[mt.type == "correctivo"].assign(p=lambda x: pd.to_datetime(x.date).dt.to_period("M")).groupby("p").size()
    j = pd.concat([mm, cc], axis=1, keys=["vol", "corr"]).dropna()
    out(f"   correctivos vs volumen mensual (emergente)  : rho {spearmanr(j["vol"], j["corr"])[0]:+.2f} (n={len(j)})")


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="../raw")
    ap.add_argument("--output", default="../fleet_synthetic")
    a = ap.parse_args()
    out_dir = Path(a.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    kag, d = load_base(Path(a.input))
    d = real_signals(d)
    veh, drv = build_fleet(d, kag)
    d = assign_drivers(d, drv)
    d = operational_vars(d, kag)
    mt = build_maintenance(d, veh)
    inc = build_incidents(d, veh, mt, kag)

    deliveries = d[["order_id", "vehicle_id", "driver_id", "order_purchase_timestamp",
                    "order_delivered_carrier_date", "order_delivered_customer_date", "distance_km",
                    "route_state", "delivery_status", "eta_variation_hours", "loading_unloading_time_h",
                    "route_risk_level", "traffic_congestion_level", "weather_condition_severity"]].copy()
    deliveries.columns = ["order_id", "vehicle_id", "driver_id", "pickup_date", "carrier_pickup_date",
                          "delivery_date", "distance_km", "route_state", "delivery_status",
                          "eta_variation_hours", "loading_unloading_time_h", "route_risk_level",
                          "traffic_congestion_level", "weather_condition_severity"]
    deliveries.insert(0, "delivery_id", range(1, len(deliveries) + 1))

    veh.drop(columns="_base_state").to_csv(out_dir / "fleet_vehicles.csv", index=False)
    drv.drop(columns=[c for c in drv.columns if c.startswith("_")]).to_csv(out_dir / "fleet_drivers.csv", index=False)
    deliveries.to_csv(out_dir / "fleet_deliveries.csv", index=False)
    mt.to_csv(out_dir / "fleet_maintenance.csv", index=False)
    inc.to_csv(out_dir / "fleet_incidents.csv", index=False)

    log = [f"generate_fleet_dataset.py | SEED={SEED}",
           f"vehículos={len(veh)} conductores={len(drv)} entregas={len(deliveries):,} "
           f"mantenimientos={len(mt):,} incidentes={len(inc):,}",
           f"EFFECTS={EFFECTS}", f"BEHAVIOR_BETA={BEHAVIOR_BETA} FATIGUE_BETA={FATIGUE_BETA} "
           f"INCIDENT_RATE={INCIDENT_RATE} ASSIGN_BY={ASSIGN_BY}"]
    validate(d, veh, drv, mt, inc, kag, log)
    (out_dir / "fleet_generation_log.txt").write_text("\n".join(log), encoding="utf-8")
    print(f"\nListo. Archivos en {out_dir.resolve()}")


if __name__ == "__main__":
    main()
