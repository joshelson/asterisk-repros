-- Run on first postgres startup. Two test tables:
-- 1. `lookup` — used by func_odbc's ODBC_LOOKUP for the dialplan tight-loop
-- 2. `rt_test` — used by ${REALTIME(...)} via res_config_odbc to exercise
--    the same code path that PJSIP realtime uses (sorcery -> realtime ->
--    res_config_odbc -> ast_odbc_request_obj -> odbc_class_find).

CREATE TABLE IF NOT EXISTS lookup (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT INTO lookup (key, value) VALUES
    ('alice',   'a-result'),
    ('bob',     'b-result'),
    ('charlie', 'c-result'),
    ('dave',    'd-result'),
    ('eve',     'e-result')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS rt_test (
    id     TEXT PRIMARY KEY,
    name   TEXT NOT NULL,
    value  TEXT NOT NULL,
    commented TEXT
);

INSERT INTO rt_test (id, name, value) VALUES
    ('e1', 'endpoint-1', 'rt-value-1'),
    ('e2', 'endpoint-2', 'rt-value-2'),
    ('e3', 'endpoint-3', 'rt-value-3'),
    ('e4', 'endpoint-4', 'rt-value-4'),
    ('e5', 'endpoint-5', 'rt-value-5')
ON CONFLICT (id) DO NOTHING;

GRANT SELECT ON lookup TO asterisk;
GRANT SELECT ON rt_test TO asterisk;
