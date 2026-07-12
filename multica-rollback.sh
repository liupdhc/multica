#!/usr/bin/env bash
# ============================================================================
#  Multica 手动回滚
#  放在仓库根目录，从 backups/ 中选择备份进行恢复
# ============================================================================
#
#  用法:
#    bash scripts/rollback.sh                    # 回滚到最近一次备份
#    bash scripts/rollback.sh --list             # 列出所有备份
#    bash scripts/rollback.sh --from <备份名>     # 指定备份
#    bash scripts/rollback.sh --db-only          # 仅恢复数据库
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/Makefile" && -f "${SCRIPT_DIR}/docker-compose.selfhost.yml" ]]; then
    REPO_DIR="$SCRIPT_DIR"
else
    REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
BACKUP_ROOT="${REPO_DIR}/backups"
LOG_DIR="${REPO_DIR}/logs"
HEALTH_TIMEOUT=90

TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/rollback_${TS}.log"
MODE="full"
PICK=""

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_ok()   { log "OK:    $*"; }
log_warn() { log "WARN:  $*"; }
log_err()  { log "ERROR: $*"; }
die()      { log_err "$*"; exit 1; }

read_env() {
    local val
    val=$(grep "^${1}=" "${REPO_DIR}/.env" 2>/dev/null | cut -d= -f2-)
    echo "${val:-$2}"
}

# ── 列出备份 ────────────────────────────────────────────────────────────────

list_backups() {
    [[ -d "$BACKUP_ROOT" ]] || die "备份目录不存在: ${BACKUP_ROOT}"
    local dirs=()
    while IFS= read -r d; do [[ -d "$d" ]] && dirs+=("$d"); done \
        < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -not -name '_*' | sort -r)
    [[ ${#dirs[@]} -gt 0 ]] || die "没有可用备份"

    echo ""
    printf "  %-4s  %-20s  %-10s  %-10s  %-14s\n" "#" "时间" "数据库" "上传文件" "Git SHA"
    echo "  ──────────────────────────────────────────────────────────────"
    local i=1
    for d in "${dirs[@]}"; do
        local name=$(basename "$d")
        local pretty=$(echo "$name" | sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')
        local db="✗" up="✗" sha="-"
        [[ -f "$d/db.dump" ]] && db="$(du -sh "$d/db.dump" | awk '{print $1}')"
        [[ -d "$d/uploads" ]] && up="$(find "$d/uploads" -type f | wc -l | tr -d ' ')个"
        [[ -f "$d/git-sha.txt" ]] && sha="$(cat "$d/git-sha.txt" | cut -c1-12)"
        printf "  %-4s  %-20s  %-10s  %-10s  %-14s\n" "[$i]" "$pretty" "$db" "$up" "$sha"
        i=$((i+1))
    done
    echo ""
}

# ── 选备份 ──────────────────────────────────────────────────────────────────

pick_backup() {
    if [[ -n "$PICK" ]]; then
        [[ -d "${BACKUP_ROOT}/${PICK}" ]] || die "备份不存在: ${PICK}"
        echo "${BACKUP_ROOT}/${PICK}"
        return
    fi
    local latest
    latest=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -not -name '_*' | sort -r | head -1)
    [[ -n "$latest" ]] || die "没有可用备份"
    echo "$latest"
}

# ── 恢复数据库 ──────────────────────────────────────────────────────────────

restore_db() {
    local bdir="$1"
    [[ -f "${bdir}/db.dump" ]] || { log_warn "备份中无 db.dump"; return 1; }

    log "恢复数据库..."
    local pg_user pg_db pg_c
    pg_user=$(read_env POSTGRES_USER multica)
    pg_db=$(read_env POSTGRES_DB multica)

    # 确保 postgres 在运行
    pg_c=$(docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" ps -q postgres 2>/dev/null || true)
    if [[ -z "$pg_c" ]]; then
        docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" up -d postgres 2>&1 | tee -a "$LOG_FILE"
        sleep 8
        pg_c=$(docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" ps -q postgres 2>/dev/null || true)
        [[ -z "$pg_c" ]] && die "PostgreSQL 启动失败"
    fi

    docker exec "$pg_c" psql -U "$pg_user" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${pg_db}' AND pid <> pg_backend_pid();" 2>/dev/null || true
    docker exec "$pg_c" psql -U "$pg_user" -d postgres \
        -c "DROP DATABASE IF EXISTS \"${pg_db}\";" 2>>"$LOG_FILE"
    docker exec "$pg_c" psql -U "$pg_user" -d postgres \
        -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" 2>>"$LOG_FILE"
    docker exec -i "$pg_c" pg_restore -U "$pg_user" -d "$pg_db" \
        --no-owner --no-privileges < "${bdir}/db.dump" 2>>"$LOG_FILE" || true
    log_ok "数据库已恢复"
}

# ── 恢复 uploads ────────────────────────────────────────────────────────────

restore_uploads() {
    local bdir="$1"
    [[ -d "${bdir}/uploads" && "$(ls -A "${bdir}/uploads" 2>/dev/null)" ]] || { log_warn "备份中无 uploads"; return 1; }

    local vol
    vol=$(docker volume ls --format '{{.Name}}' | grep 'backend_uploads' | head -1 || true)
    [[ -n "$vol" ]] || { log_warn "未找到 uploads 卷"; return 1; }

    docker run --rm -v "${vol}:/dst" -v "${bdir}/uploads:/src:ro" \
        alpine:latest sh -c 'rm -rf /dst/* 2>/dev/null; cp -a /src/. /dst/' 2>>"$LOG_FILE"
    log_ok "uploads 已恢复"
}

# ── 健康检查 ────────────────────────────────────────────────────────────────

health_check() {
    local elapsed=0 pg=false be=false fe=false
    while [[ $elapsed -lt $HEALTH_TIMEOUT ]]; do
        if [[ "$pg" == "false" ]]; then
            local c; c=$(docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" ps -q postgres 2>/dev/null || true)
            [[ -n "$c" && "$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null)" == "healthy" ]] && { pg=true; log_ok "PostgreSQL ✓"; }
        fi
        if [[ "$pg" == "true" && "$be" == "false" ]]; then
            local code; code=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:$(read_env BACKEND_PORT 8080)/health" 2>/dev/null || echo 000)
            [[ "$code" =~ ^(200|301|302)$ ]] && { be=true; log_ok "Backend ✓"; }
        fi
        if [[ "$be" == "true" && "$fe" == "false" ]]; then
            local code; code=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:$(read_env FRONTEND_PORT 3000)" 2>/dev/null || echo 000)
            [[ "$code" =~ ^(200|301|302|307)$ ]] && { fe=true; log_ok "Frontend ✓"; }
        fi
        [[ "$pg" == "true" && "$be" == "true" && "$fe" == "true" ]] && return 0
        sleep 5; elapsed=$((elapsed+5))
    done
    log_err "健康检查超时 (PG:${pg} BE:${be} FE:${fe})"
    return 1
}

# ── 主流程 ──────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$LOG_DIR"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list|-l)      list_backups; exit 0 ;;
            --from)         PICK="${2:-}"; shift ;;
            --db-only)      MODE="db-only" ;;
            --uploads-only) MODE="uploads-only" ;;
            -h|--help)
                echo "用法: bash $0 [--list|--from <名称>|--db-only|--uploads-only]"
                exit 0 ;;
        esac
        shift
    done

    log "════════════════════════════════════════════════"
    log "  Multica 回滚 - $(date '+%Y-%m-%d %H:%M:%S')"
    log "════════════════════════════════════════════════"

    local bdir
    bdir=$(pick_backup)
    log "备份来源: $(basename "$bdir")"

    # 确认
    echo ""
    echo "  将执行: ${MODE} 回滚"
    echo "  ⚠  会覆盖当前数据库/配置"
    echo ""
    read -rp "输入 yes 继续: " ok
    [[ "$ok" == "yes" ]] || { log "已取消"; exit 0; }

    case "$MODE" in
        full)
            # 停服务
            docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" down 2>&1 | tee -a "$LOG_FILE" || true

            # 恢复 git 版本
            if [[ -f "${bdir}/git-sha.txt" ]]; then
                local sha; sha=$(cat "${bdir}/git-sha.txt")
                log "git checkout ${sha:0:12}..."
                git -C "$REPO_DIR" checkout "$sha" 2>&1 | tee -a "$LOG_FILE" || true
            fi
            # 恢复 .env
            [[ -f "${bdir}/.env" ]] && { cp "${bdir}/.env" "${REPO_DIR}/.env"; log_ok ".env 已恢复"; }

            restore_db "$bdir"
            restore_uploads "$bdir"

            # 将旧镜像 ID 重新 tag，防止 compose pull 拉到新版本
            if [[ -f "${bdir}/image-ids.env" ]]; then
                source "${bdir}/image-ids.env"
                local be_tag fe_tag pg_tag
                be_tag=$(read_env MULTICA_BACKEND_IMAGE "ghcr.io/multica-ai/multica-backend"):$(read_env MULTICA_IMAGE_TAG "latest")
                fe_tag=$(read_env MULTICA_WEB_IMAGE "ghcr.io/multica-ai/multica-web"):$(read_env MULTICA_IMAGE_TAG "latest")
                pg_tag="pgvector/pgvector:pg17"
                [[ -n "$BACKEND_IMAGE_ID" ]]  && docker tag "$BACKEND_IMAGE_ID"  "$be_tag" 2>/dev/null || true
                [[ -n "$FRONTEND_IMAGE_ID" ]] && docker tag "$FRONTEND_IMAGE_ID" "$fe_tag" 2>/dev/null || true
                [[ -n "$POSTGRES_IMAGE_ID" ]] && docker tag "$POSTGRES_IMAGE_ID" "$pg_tag" 2>/dev/null || true
                log_ok "已将旧镜像重新 tag"
            fi

            log "docker compose up -d (不 pull，使用本地旧镜像)..."
            docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" up -d 2>&1 | tee -a "$LOG_FILE" || die "docker compose up 失败"

            # 切回分支
            local branch; branch=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
            git -C "$REPO_DIR" checkout "$branch" 2>/dev/null || true

            health_check || log_err "请手动检查日志"
            ;;
        db-only)
            docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" stop backend 2>&1 | tee -a "$LOG_FILE" || true
            restore_db "$bdir"
            docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" up -d backend frontend 2>&1 | tee -a "$LOG_FILE"
            health_check || log_err "请手动检查日志"
            ;;
        uploads-only)
            restore_uploads "$bdir"
            docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" restart backend 2>&1 | tee -a "$LOG_FILE" || true
            health_check || true
            ;;
    esac

    log "════════════════════════════════════════════════"
    log "  回滚完成 - 日志: ${LOG_FILE}"
    log "════════════════════════════════════════════════"
}

main "$@"
