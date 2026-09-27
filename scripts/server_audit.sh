#!/usr/bin/env bash
# Инвентаризация сервера для ETL-проекта по маркетплейсам.
# Скрипт ТОЛЬКО ЧИТАЕТ систему: ничего не устанавливает, не меняет и не перезапускает.
# Значения секретов (токены, пароли, ключи) в отчёт не попадают — выводятся только имена.
#
# Запуск:
#   bash server_audit.sh                 # отчёт в ./server_audit_<host>_<дата>.txt
#   sudo bash server_audit.sh            # полнее: видны чужие crontab, systemd-юниты, порты всех процессов
#   SEARCH_ROOTS="/opt /srv /home" bash server_audit.sh

set -u
SEARCH_ROOTS="${SEARCH_ROOTS:-/opt /srv /home /root /var/www /usr/local/bin /etc/systemd/system}"
OUT="${OUT:-./server_audit_$(hostname -s)_$(date +%Y%m%d_%H%M).txt}"
MAXDEPTH="${MAXDEPTH:-6}"

# Маскирует значения всего, что похоже на секрет: KEY=..., "token": "...", Bearer ..., пароли в URL.
redact() {
  sed -E \
    -e 's/((api[_-]?key|apikey|token|secret|password|passwd|pwd|client[_-]?secret|authorization|auth|private[_-]?key|access[_-]?key|bearer)[A-Za-z0-9_-]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^"'"'"' ,}]+/\1***REDACTED***/Ig' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***REDACTED***/Ig' \
    -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***REDACTED***@#g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/***JWT_REDACTED***/g'
}

section() { printf '\n\n==================== %s ====================\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
run() { echo "\$ $*"; "$@" 2>&1 | redact; }

find_in_roots() {
  # shellcheck disable=SC2086
  find $SEARCH_ROOTS -maxdepth "$MAXDEPTH" \
    \( -name node_modules -o -name .git -o -name __pycache__ -o -name site-packages -o -name .cache -o -name .npm -o -name .venv -o -name venv \) -prune -o \
    "$@" -print 2>/dev/null
}

{
echo "Server audit report"
echo "Generated: $(date -Is)  Host: $(hostname)  User: $(id -un) (uid $(id -u))"
echo "Search roots: $SEARCH_ROOTS"

section "1. ОС и ресурсы"
run uname -a
[ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
run uptime
have free && run free -h
run df -h -x tmpfs -x devtmpfs
have timedatectl && timedatectl 2>/dev/null | grep -Ei 'time zone|synchronized'

section "2. Среды выполнения"
for c in python3 python pip3 node npm npx uv uvx poetry docker docker-compose psql sqlite3 git crontab airflow; do
  if have "$c"; then printf '%-15s %s  (%s)\n' "$c" "$(command -v "$c")" "$("$c" --version 2>&1 | head -1)"; else printf '%-15s —\n' "$c"; fi
done

section "3. Процессы MCP / Python / Node"
ps -eo pid,user,etimes,rss,args --sort=-rss 2>/dev/null \
  | grep -Ei 'mcp|python|node|uvx|npx|airflow|cron|postgres|gunicorn|uvicorn' | grep -v grep | cut -c1-400 | redact

section "4. Слушающие порты"
if have ss; then run ss -tulpn; elif have netstat; then run netstat -tulpn; fi

section "5. systemd: сервисы и таймеры"
if have systemctl; then
  systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep -vE '^(systemd-|dbus|getty|user@)' | head -80
  echo; systemctl list-timers --all --no-pager 2>/dev/null | head -40
  echo; echo "--- Нестандартные юниты (/etc/systemd/system, ~/.config/systemd/user) ---"
  for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer /root/.config/systemd/user/*.service /home/*/.config/systemd/user/*.{service,timer}; do
    [ -f "$f" ] || continue
    echo "### $f"; grep -Ev '^\s*(#|$)' "$f" | redact
  done
fi

section "6. Cron"
echo "--- crontab текущего пользователя ---"; crontab -l 2>&1 | redact
if [ "$(id -u)" = 0 ]; then
  for u in $(cut -d: -f1 /etc/passwd); do
    c=$(crontab -l -u "$u" 2>/dev/null) && { echo "--- crontab $u ---"; echo "$c" | redact; }
  done
fi
for f in /etc/crontab /etc/cron.d/*; do [ -f "$f" ] && { echo "--- $f ---"; grep -Ev '^\s*(#|$)' "$f" | redact; }; done
ls -la /etc/cron.daily /etc/cron.hourly 2>/dev/null

section "7. Docker"
if have docker; then
  run docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  find_in_roots -type f \( -name 'docker-compose*.yml' -o -name 'compose*.yml' -o -name 'compose*.yaml' -o -name Dockerfile \)
fi

section "8. Конфигурации MCP-серверов"
find_in_roots -type f \( -name '.mcp.json' -o -name 'mcp.json' -o -name 'mcp_config*.json' -o -name 'claude_desktop_config.json' -o -name 'settings.json' -path '*claude*' -o -name 'config.json' -path '*mcp*' \) \
  | while read -r f; do echo "### $f"; head -c 6000 "$f" | redact; echo; done
echo "--- Каталоги/пакеты с 'mcp' в имени ---"
find_in_roots -type d -iname '*mcp*' | head -50
for d in /usr/lib/node_modules /usr/local/lib/node_modules; do [ -d "$d" ] && ls "$d" | grep -i mcp; done
pip3 list 2>/dev/null | grep -Ei 'mcp|fastmcp|anthropic'

section "9. Проекты и скрипты (Python/Node/Shell)"
echo "--- Корни проектов ---"
find_in_roots -type f \( -name requirements.txt -o -name pyproject.toml -o -name package.json -o -name Pipfile -o -name setup.py \) | head -100
echo; echo "--- Файлы, упоминающие маркетплейсы/Google Sheets/БД ---"
# shellcheck disable=SC2086
grep -rIlE --include='*.py' --include='*.js' --include='*.ts' --include='*.sh' --include='*.json' --include='*.yml' --include='*.yaml' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=venv --exclude-dir=.venv --exclude-dir=site-packages \
  -i 'wildberries|wb\.ru|ozon|api-seller|yandex.*market|partner\.market|megamarket|sbermegamarket|aliexpress|avito|gspread|googleapis.*sheets|spreadsheet|sqlite3|psycopg|sqlalchemy|fastmcp|modelcontextprotocol' \
  $SEARCH_ROOTS 2>/dev/null | head -200 | while read -r f; do
    printf '%s  [%s строк, изменён %s]\n' "$f" "$(wc -l <"$f")" "$(date -r "$f" +%F)"
  done
echo; echo "--- Какие площадки/API упоминаются (по числу файлов) ---"
for p in wildberries ozon 'yandex|partner\.market' megamarket aliexpress avito gspread sqlite psycopg fastmcp; do
  # shellcheck disable=SC2086
  n=$(grep -rIliE --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=venv --exclude-dir=.venv --exclude-dir=site-packages "$p" $SEARCH_ROOTS 2>/dev/null | grep -Ec '\.(py|js|ts|sh)$')
  printf '%-25s %s\n' "$p" "$n"
done
echo; echo "--- Функции/эндпоинты в найденных Python-файлах (def, @mcp.tool, URL API) ---"
# shellcheck disable=SC2086
grep -rIlE --include='*.py' --exclude-dir=venv --exclude-dir=.venv --exclude-dir=site-packages -i 'wildberries|ozon|market|gspread|mcp' $SEARCH_ROOTS 2>/dev/null | head -60 | while read -r f; do
  echo "### $f"
  grep -nE '^\s*(async\s+)?def |@(mcp|server|app)\.(tool|resource|prompt)|https?://[a-z0-9.-]*(wildberries|wb\.ru|ozon|market\.yandex|api\.partner|googleapis)' "$f" | head -40 | redact
done

section "10. Хранилища данных"
echo "--- SQLite-файлы ---"
find_in_roots -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -size +0 | head -50 | while read -r f; do
  printf '%s  (%s)\n' "$f" "$(du -h "$f" | cut -f1)"
  have sqlite3 && sqlite3 -readonly "$f" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null | sed 's/^/    table: /'
done
echo "--- PostgreSQL ---"
if have psql; then
  (pg_lsclusters 2>/dev/null || true)
  [ "$(id -u)" = 0 ] && su - postgres -c "psql -Atc \"SELECT datname FROM pg_database WHERE NOT datistemplate\"" 2>/dev/null | sed 's/^/    db: /'
fi

section "11. Файлы с учётными данными (только имена, без содержимого)"
find_in_roots -type f \( -name '.env' -o -name '*.env' -o -name 'credentials*.json' -o -name 'service_account*.json' -o -name '*-sa.json' -o -name 'token*.json' -o -name '*.pem' \) | head -60 \
  | while read -r f; do printf '%s  perms=%s owner=%s\n' "$f" "$(stat -c %a "$f")" "$(stat -c %U "$f")"; done
echo "--- Имена переменных в .env (без значений) ---"
find_in_roots -type f \( -name '.env' -o -name '*.env' \) | head -20 | while read -r f; do
  echo "### $f"; grep -oE '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=' "$f" | tr -d ' ='
done

section "12. Логи (последние строки, с маскировкой)"
find_in_roots -type f -name '*.log' -mtime -14 | head -20 | while read -r f; do
  echo "### $f ($(du -h "$f" | cut -f1))"; tail -n 15 "$f" | cut -c1-300 | redact
done
if have journalctl; then
  for u in $(systemctl list-units --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'mcp|etl|market|wb|ozon|sheet'); do
    echo "### journal $u"; journalctl -u "$u" -n 20 --no-pager 2>/dev/null | cut -c1-300 | redact
  done
fi

echo; echo "=== Конец отчёта ==="
} > "$OUT" 2>&1

echo "Готово: $OUT ($(wc -l <"$OUT") строк)."
echo "Перед отправкой просмотрите файл: секреты маскируются автоматически, но проверьте глазами."
