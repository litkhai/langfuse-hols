#!/usr/bin/env python3
"""01-setup.py — create the lab's database and tables (01-schema.sql) and download the model.

Idempotent. Prints the ClickHouse version and the settings the vector index depends on,
read from the live server, and the model's dimension.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

sql = open(os.path.join(L.LAB_DIR, "01-schema.sql")).read()
stmts = [s.strip() for s in "\n".join(
    line for line in sql.splitlines() if not line.strip().startswith("--")).split(";") if s.strip()]
for s in stmts:
    L.ch(s)
print("ClickHouse", L.ch("SELECT version()").strip())
print(L.ch("SELECT name, value, tier FROM system.settings WHERE name IN "
           "('hnsw_candidate_list_size_for_search','max_limit_for_vector_search_queries',"
           "'vector_search_with_rescoring','vector_search_filter_strategy','enable_vector_similarity_index') "
           "ORDER BY name FORMAT PrettyCompactMonoBlock"))
print(L.ch(f"SELECT name, engine, total_rows FROM system.tables WHERE database = '{L.DB}' "
           "ORDER BY name FORMAT PrettyCompactMonoBlock"))
m = L.model()
print(f"model {L.MODEL_ID}@{L.MODEL_REVISION[:7]} dim={m.get_embedding_dimension()} device={m.device}")
