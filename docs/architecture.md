# ETL по маркетплейсам: целевая архитектура и чек-лист доработок

## 1. Поток данных

```
 cron / systemd timer (ежедневно, напр. 06:00 МСК)
        │
        ▼
 ┌──────────────┐   raw JSON    ┌───────────────┐  единая схема  ┌──────────────┐        ┌───────────────┐
 │  Extractor   │ ────────────▶ │  Transformer  │ ─────────────▶ │  Хранилище   │ ─────▶ │ Google Sheets │
 │ (API WB/Ozon │  raw_* табл.  │ (SKU-маппинг, │  fact_* табл.  │ SQLite/PgSQL │ витрины│ (дашборды)    │
 │  /ЯМ/...)    │               │  валюты, даты)│                │              │        │               │
 └──────────────┘               └───────────────┘                └──────────────┘        └───────────────┘
        ▲                                                                ▲
        └──── MCP-серверы (уже на сервере): переиспользовать как клиенты API или для ad-hoc запросов к БД
```

Ключевой принцип: **Google Sheets — только витрина**, а не основное хранилище. Там лимиты (10 млн ячеек, квоты API),
нет транзакций, и история легко теряется. Источник правды — БД, а в Sheets выгружаются агрегаты.

## 2. Компоненты

| # | Компонент | Реализация | Что должно быть |
|---|-----------|------------|-----------------|
| 1 | Extractor | Python, отдельный модуль на каждую площадку (`extractors/wb.py`, `ozon.py`, `ym.py`) | Пагинация, ретраи с backoff (429/5xx), соблюдение rate-limit, инкрементальная выгрузка по датам, сохранение «сырого» ответа |
| 2 | Transformer | Python (pandas или чистый SQL) | Справочник `sku_map` (внутренний ID ↔ nmID WB ↔ offer_id/sku Ozon ↔ shopSku ЯМ), единые даты (UTC/МСК), валюта, дедупликация |
| 3 | Хранилище | PostgreSQL (для нескольких площадок и истории); SQLite подходит для MVP | Слои `raw_*` → `fact_*` → `mart_*`; UPSERT по ключу (площадка, sku, дата) |
| 4 | Планировщик | cron или systemd timer; Airflow — только если DAG станет больше 10 задач | Lock от параллельных запусков (`flock`), лог, алерт при падении |
| 5 | Визуализация | Google Sheets через `gspread` + service account | Отдельный лист на витрину, полная перезапись диапазона, лист «Обновлено» с датой и статусом |

## 3. Минимальная модель данных

```sql
-- справочник сопоставления товаров
CREATE TABLE sku_map (
  internal_id   TEXT NOT NULL,          -- ваш артикул / SKU
  marketplace   TEXT NOT NULL,          -- 'wb' | 'ozon' | 'ym' ...
  mp_sku        TEXT NOT NULL,          -- nmID / sku / shopSku
  mp_offer_id   TEXT,                   -- артикул продавца на площадке
  name          TEXT,
  PRIMARY KEY (marketplace, mp_sku)
);

-- ежедневные метрики в единой схеме
CREATE TABLE fact_daily (
  dt            DATE NOT NULL,
  marketplace   TEXT NOT NULL,
  internal_id   TEXT NOT NULL,
  orders_qty    INTEGER, orders_sum NUMERIC,
  sales_qty     INTEGER, sales_sum  NUMERIC,
  returns_qty   INTEGER,
  stock_qty     INTEGER,
  price         NUMERIC,
  commission    NUMERIC, logistics NUMERIC, ads_spend NUMERIC,
  loaded_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (dt, marketplace, internal_id)
);

-- журнал запусков (для мониторинга и листа «Обновлено»)
CREATE TABLE etl_runs (
  run_id SERIAL PRIMARY KEY, started_at TIMESTAMP, finished_at TIMESTAMP,
  marketplace TEXT, step TEXT, status TEXT, rows INTEGER, error TEXT
);
```

## 4. Чек-лист аудита сервера

Заполняется по отчёту `scripts/server_audit.sh`. Статусы: ✅ есть · ⚠️ частично · ❌ нет.

| Область | Вопрос | Статус | Комментарий |
|---------|--------|--------|-------------|
| MCP | Какие MCP-серверы запущены, для каких площадок, какие tools предоставляют | | |
| MCP | Как запускаются (systemd/docker/вручную в screen), перезапускаются ли после ребута | | |
| Extract | Есть ли скрипты выгрузки по каждой площадке; какие метрики уже забираются | | |
| Extract | Ретраи, rate-limit, пагинация, инкремент по датам | | |
| Transform | Есть ли справочник SKU-маппинга между площадками | | |
| Load | Какая БД используется, есть ли схема, UPSERT или дубли | | |
| Load | Выгрузка в Google Sheets: service account, какие таблицы и листы | | |
| Schedule | cron/timer на ежедневный запуск, защита от двойного запуска | | |
| Ops | Логирование, ротация логов, алерты (Telegram/почта) при падении | | |
| Ops | Секреты в `.env` с правами 600, не в коде и не в git | | |
| Ops | Бэкап БД | | |
| Код | Git-репозиторий, зависимости зафиксированы (requirements/pyproject), venv | | |

## 5. Типовые доработки (уточняются после аудита)

1. Единый пакет `etl/` с общим HTTP-клиентом (ретраи, лимиты, логирование) вместо разрозненных скриптов.
2. Справочник `sku_map` и отчёт «несопоставленные SKU», чтобы сразу видеть новые товары.
3. Слой `raw_*` для хранения ответов API: позволяет пересчитать метрики без повторной выгрузки.
4. Идемпотентная загрузка через UPSERT, чтобы перезапуск за день не создавал дублей.
5. Обёртка запуска: `flock` + журнал `etl_runs` + уведомление об ошибке.
6. Выгрузка витрин в Google Sheets отдельным шагом после успешной загрузки в БД.
7. systemd-юниты для MCP-серверов с `Restart=always`, если сейчас они запущены вручную.

## 6. Как провести аудит

```bash
scp scripts/server_audit.sh user@server:~/
ssh user@server
sudo bash ~/server_audit.sh        # без sudo тоже работает, но покажет меньше
# при необходимости: SEARCH_ROOTS="/opt/etl /home/deploy" sudo bash ~/server_audit.sh
```

Отчёт `server_audit_<host>_<дата>.txt` нужно просмотреть: значения токенов и паролей маскируются
автоматически. Затем его можно прислать в чат или положить в репозиторий в `audit/`.
