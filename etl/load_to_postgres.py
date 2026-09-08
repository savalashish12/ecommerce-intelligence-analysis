"""
ETL Script — Load cleaned data into PostgreSQL
Run from ANY directory: python etl/load_to_postgres.py
"""

import pandas as pd
from sqlalchemy import create_engine, text
from dotenv import load_dotenv
import os
import time

# ---- Resolve paths relative to THIS script's location ----
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)          # one level up from etl/

load_dotenv(os.path.join(PROJECT_DIR, '.env'))

DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'ecommerce_db')
DB_USER = os.getenv('DB_USER', 'postgres')
DB_PASS = os.getenv('DB_PASSWORD', 'password')

conn_str = f"postgresql+psycopg2://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
engine   = create_engine(conn_str, echo=False)

RAW  = os.path.join(PROJECT_DIR, 'Data', 'Raw Data', '') +os.sep
PROC = os.path.join(PROJECT_DIR, 'Data', 'Processed Data', '') +os.sep


def load_table(df, table_name, chunksize=10000):
    start = time.time()
    print(f"  Loading {table_name:20s} ({len(df):>7,} rows) ...", end=" ", flush=True)
    df.to_sql(
        table_name, engine,
        if_exists='replace', index=False,
        chunksize=chunksize, method='multi'
    )
    print(f"done in {round(time.time() - start, 1)}s")


# ---- Test connection first ----
print(f"\nConnecting to PostgreSQL: {DB_HOST}:{DB_PORT}/{DB_NAME}")
try:
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    print("Connection OK\n")
except Exception as e:
    print(f"\nConnection FAILED: {e}")
    print("Check your .env file and make sure PostgreSQL is running.")
    raise SystemExit(1)


# ---- Load raw dimension tables ----
print("Loading raw tables...")
load_table(pd.read_csv(RAW + 'olist_customers_dataset.csv'),               'dim_customers')
load_table(pd.read_csv(RAW + 'olist_sellers_dataset.csv'),                 'dim_sellers')
load_table(pd.read_csv(RAW + 'olist_products_dataset.csv'),                'dim_products')
load_table(pd.read_csv(RAW + 'product_category_name_translation.csv'),     'dim_categories')

# ---- Load raw fact tables ----
load_table(pd.read_csv(RAW + 'olist_orders_dataset.csv'),                  'fact_orders_raw')
load_table(pd.read_csv(RAW + 'olist_order_items_dataset.csv'),             'fact_order_items')
load_table(pd.read_csv(RAW + 'olist_order_payments_dataset.csv'),          'fact_payments')
load_table(pd.read_csv(RAW + 'olist_order_reviews_dataset.csv'),           'fact_reviews')

# ---- Load cleaned master (parse dates) ----
print("\nLoading cleaned master table...")
master = pd.read_csv(PROC + 'master_orders.csv')

date_cols = [
    'order_purchase_timestamp', 'order_approved_at',
    'order_delivered_carrier_date', 'order_delivered_customer_date',
    'order_estimated_delivery_date'
]
for col in date_cols:
    master[col] = pd.to_datetime(master[col], errors='coerce')

load_table(master, 'master_orders')

# ---- Add indexes ----
print("\nCreating indexes...")
with engine.connect() as conn:
    indexes = [
        "CREATE INDEX IF NOT EXISTS idx_mo_state    ON master_orders(customer_state)",
        "CREATE INDEX IF NOT EXISTS idx_mo_year     ON master_orders(order_year)",
        "CREATE INDEX IF NOT EXISTS idx_mo_category ON master_orders(product_category_name_english)",
        "CREATE INDEX IF NOT EXISTS idx_mo_order_id ON master_orders(order_id)",
        "CREATE INDEX IF NOT EXISTS idx_mo_customer ON master_orders(customer_unique_id)",
    ]
    for sql in indexes:
        conn.execute(text(sql))
    conn.commit()
print("Indexes created.\n")

# ---- Final summary ----
print("Tables loaded into ecommerce_db:")
with engine.connect() as conn:
    result = conn.execute(text("""
        SELECT table_name,
               pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) AS size
        FROM information_schema.tables
        WHERE table_schema = 'public'
        ORDER BY table_name
    """))
    for row in result:
        print(f"  {row[0]:30s}  {row[1]}")

print("\nETL complete.")