#!/usr/bin/env bash
# Обновление hyprdesk с сохранением русского перевода.
#
#   ./hyprdesk-ru-update.sh [путь-к-репозиторию]
#
# Репозиторий — клон hyprdesk, где перевод лежит отдельным коммитом
# (ветка ru) поверх upstream. Скрипт перебазирует этот коммит на свежий
# upstream и пересобирает hyprdesk из исходников, поэтому русский перевод
# остаётся в бинарнике после каждого обновления.
#
# Переменные:
#   HYPRDESK_UPSTREAM  ветка upstream (по умолчанию origin/main)
#   HYPRDESK_REPO      путь к репозиторию, если не передан аргументом
set -euo pipefail

REPO="${1:-${HYPRDESK_REPO:-$PWD}}"
cd "$REPO"

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "Не git-репозиторий: $REPO" >&2
    echo "Укажите путь: $0 ~/src/hyprdesk" >&2
    exit 1
}

# В клоне приватного репозитория origin/main — это ветка с комплектом, а не
# upstream. Если добавлен remote upstream, берём upstream/main, иначе origin/main.
UPSTREAM="${HYPRDESK_UPSTREAM:-}"
if [[ -z "$UPSTREAM" ]]; then
    if git remote get-url upstream >/dev/null 2>&1; then
        UPSTREAM="upstream/main"
    else
        UPSTREAM="origin/main"
    fi
fi
REMOTE="${UPSTREAM%%/*}"
BRANCH="${UPSTREAM#*/}"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "Есть незакоммиченные изменения. Закоммитьте их или уберите (git stash) и повторите." >&2
    exit 1
fi

git config rerere.enabled true

echo "→ git fetch $REMOTE"
git fetch --prune "$REMOTE"

if ! git merge-base "$UPSTREAM" HEAD >/dev/null 2>&1; then
    cat >&2 <<EOF
У $UPSTREAM нет общей истории с текущей веткой — это не upstream hyprdesk.
Добавьте его и повторите:
    git remote add upstream https://github.com/jacquesh82/hyprdesk
    HYPRDESK_UPSTREAM=upstream/main $0 "$REPO"
EOF
    exit 1
fi

echo "→ git rebase $UPSTREAM"
if ! git rebase "$UPSTREAM"; then
    cat >&2 <<'EOF'

Конфликт при rebase. Разрешите его вручную, затем:
    git add -A && git rebase --continue
и снова запустите этот скрипт.

Частые места конфликтов: locales/en.toml (upstream добавил строки рядом)
и перечисления языков в src/cli_config.rs / src/config/lua.rs.
EOF
    exit 1
fi

# Полнота каталога: новые строки upstream должны появиться в ru.toml.
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' || exit 1
import re
import sys
import tomllib

try:
    en = tomllib.load(open("locales/en.toml", "rb"))
    ru = tomllib.load(open("locales/ru.toml", "rb"))
except FileNotFoundError:
    sys.exit(0)

holes = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\}")
missing = [k for k in en if k not in ru]
extra = [k for k in ru if k not in en]
bad = [k for k, v in ru.items() if sorted(holes.findall(k)) != sorted(holes.findall(v))]

if extra:
    print(f"Предупреждение: {len(extra)} ключей в ru.toml больше нет в en.toml.", file=sys.stderr)

if bad:
    print(f"Ошибка: плейсхолдеры не совпадают в {len(bad)} строках:", file=sys.stderr)
    for k in bad[:15]:
        print("  " + k[:100].replace("\n", "\\n"), file=sys.stderr)
    sys.exit(1)

if missing:
    print(f"Внимание: {len(missing)} новых строк ещё без перевода "
          f"(пока покажутся по-французски):", file=sys.stderr)
    for k in missing[:25]:
        print("  " + k[:120].replace("\n", "\\n"), file=sys.stderr)
    if len(missing) > 25:
        print(f"  … ещё {len(missing) - 25}", file=sys.stderr)
    print("Добавьте их в locales/ru.toml и закоммитьте в ветку ru.", file=sys.stderr)
PY
fi

echo "→ сборка и установка (Rust, ~3–10 мин при первой сборке)"
./scripts/install.sh --from-source --lang ru --no-greeter --optional-deps none

echo
echo "Готово. Проверка: hyprdesk config get language   (ожидается: ru)"
if [[ -x /usr/local/bin/hyprdesk ]]; then
    echo "Если пользуетесь экраном входа hyprdesk, обновите его копию:"
    echo "    ./scripts/update.sh --yes"
fi
