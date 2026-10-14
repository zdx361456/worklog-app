/// SQLite 数据库 Schema（基础版）
/// 对应 03 §2/§3/§6.6。
///
/// - 六实体各一张表，记录级 CRUD。
/// - 统一审计列：id(UUID) / created_at / updated_at / deleted_at(软删)。
/// - 金额定点整数「分」，倍率整数「×10」。
/// - 唯一约束：HolidayMark (ledger_id, date)（03 §3.1）。
/// - 基础版无 rev/device_id/dirty 等同步字段（用户决策：完全不做云）。
///
/// 本文件只定义 Schema 与建表 SQL（纯 Dart，不依赖 sqflite），
/// 具体的 sqflite 打开/迁移在 Flutter 运行时接上（db/database.dart）。
library;

/// 数据库版本号；升版时在此登记迁移（二期加借支/周期表时 +1）。
const int kDbVersion = 1;

/// 六张表的建表 SQL（幂等：CREATE TABLE IF NOT EXISTS）。
const List<String> kCreateTableStatements = [
  // 账本
  '''
  CREATE TABLE IF NOT EXISTS ledger (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    currency    TEXT NOT NULL DEFAULT 'CNY',
    mode        TEXT NOT NULL DEFAULT 'local',  -- local | cloud（基础版恒 local）
    created_at  TEXT NOT NULL
  )
  ''',
  // 公司
  '''
  CREATE TABLE IF NOT EXISTS company (
    id              TEXT PRIMARY KEY,
    ledger_id       TEXT NOT NULL,
    name            TEXT NOT NULL,
    short_name      TEXT,
    tag_color       INTEGER NOT NULL,
    default_rule_id TEXT,
    enabled         INTEGER NOT NULL DEFAULT 1,
    contact         TEXT,
    currency        TEXT NOT NULL DEFAULT 'CNY',
    note            TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT
  )
  ''',
  // 计价规则
  '''
  CREATE TABLE IF NOT EXISTS pricing_rule (
    id             TEXT PRIMARY KEY,
    company_id     TEXT NOT NULL,
    name           TEXT NOT NULL,
    method         TEXT NOT NULL,          -- hourly | daily | piece
    base_rate      INTEGER NOT NULL,       -- 分
    unit           TEXT,
    standard_hours REAL,
    half_day_ratio INTEGER NOT NULL DEFAULT 5,   -- ×10
    overtime_rate  INTEGER NOT NULL DEFAULT 15,  -- ×10
    weekend_rate   INTEGER NOT NULL DEFAULT 10,  -- ×10
    holiday_rate   INTEGER NOT NULL DEFAULT 10,  -- ×10
    effective_date TEXT,
    enabled        INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL,
    deleted_at     TEXT
  )
  ''',
  // 工作记录（快照五件套）
  '''
  CREATE TABLE IF NOT EXISTS work_record (
    id                     TEXT PRIMARY KEY,
    company_id             TEXT NOT NULL,
    pricing_rule_id        TEXT,            -- 弱引用（允许悬空）
    attribution_date       TEXT NOT NULL,   -- yyyy-MM-dd
    mode_snapshot          TEXT NOT NULL,   -- hourly | daily | piece
    quantity               REAL NOT NULL,   -- 物理量
    quantity_unit_snapshot TEXT,
    start_time             TEXT,            -- HH:mm
    end_time               TEXT,            -- HH:mm
    is_overnight           INTEGER NOT NULL DEFAULT 0,
    unit_price_snapshot    INTEGER NOT NULL, -- 分
    rate_overtime_hit      INTEGER NOT NULL DEFAULT 0,   -- 是否命中加班
    rate_overtime_rate     INTEGER NOT NULL DEFAULT 10,  -- 倍率 ×10
    rate_weekend_hit       INTEGER NOT NULL DEFAULT 0,
    rate_weekend_rate      INTEGER NOT NULL DEFAULT 10,
    rate_holiday_hit       INTEGER NOT NULL DEFAULT 0,
    rate_holiday_rate      INTEGER NOT NULL DEFAULT 10,
    rate_applied           INTEGER NOT NULL DEFAULT 10,  -- 取用倍率 ×10
    amount_snapshot        INTEGER NOT NULL, -- 分
    amount_source          TEXT NOT NULL,     -- auto | manual
    auto_reference         INTEGER,           -- 分
    currency               TEXT,              -- 币种快照，继承账本
    note                   TEXT,
    status                 TEXT NOT NULL DEFAULT 'confirmed', -- draft | confirmed | settled
    created_at             TEXT NOT NULL,
    updated_at             TEXT NOT NULL,
    deleted_at             TEXT
  )
  ''',
  // 收款记录
  '''
  CREATE TABLE IF NOT EXISTS payment_record (
    id           TEXT PRIMARY KEY,
    company_id   TEXT NOT NULL,
    pay_date     TEXT NOT NULL,            -- yyyy-MM-dd
    amount       INTEGER NOT NULL,         -- 分
    method       TEXT,                     -- cash | wechat | alipay | bank | other
    note         TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    deleted_at   TEXT
  )
  ''',
  // 节假日标记（唯一约束 ledger_id + date）
  '''
  CREATE TABLE IF NOT EXISTS holiday_mark (
    id          TEXT PRIMARY KEY,
    ledger_id   TEXT NOT NULL,
    date        TEXT NOT NULL,             -- yyyy-MM-dd
    type        TEXT NOT NULL,             -- statutory | working_swap | custom
    rate        INTEGER NOT NULL,          -- ×10
    manual      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    UNIQUE (ledger_id, date)
  )
  ''',
];

/// 建表时建议加的索引（按派生查询热点）。
/// - 月历按**归属日范围跨公司**聚合 → 需单独 attribution_date 索引（03 §7.1）。
/// - 单公司下钻按 (company_id, date)。
const List<String> kCreateIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_work_record_attribution_date ON work_record (attribution_date)',
  'CREATE INDEX IF NOT EXISTS idx_work_record_company_date ON work_record (company_id, attribution_date)',
  'CREATE INDEX IF NOT EXISTS idx_payment_company_date ON payment_record (company_id, pay_date)',
  'CREATE INDEX IF NOT EXISTS idx_rule_company ON pricing_rule (company_id)',
  'CREATE INDEX IF NOT EXISTS idx_holiday_ledger_date ON holiday_mark (ledger_id, date)',
];
