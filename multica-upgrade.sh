#!/usr/bin/env bash
# ============================================================================
#  Multica 自动升级 & 失败回滚
#  放在仓库根目录，配合 git pull + make selfhost 使用
# ============================================================================
#
#  用法:
#    bash scripts/upgrade.sh                    # 执行升级
#    bash scripts/upgrade.sh --dry-run          # 仅检查是否有新版本
#    bash scripts/upgrade.sh --install-cron     # 安装定时任务（每周日 03:00）
#    bash scripts/upgrade.sh --uninstall-cron   # 卸载定时任务
#
set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 自动定位仓库根目录：脚本在根目录则直接用，在 scripts/ 子目录则上跳一级
if [[ -f "${SCRIPT_DIR}/Makefile" && -f "${SCRIPT_DIR}/docker-compose.selfhost.yml" ]]; then
    REPO_DIR="$SCRIPT_DIR"
else
    REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
BACKUP_ROOT="${REPO_DIR}/backups"
LOG_DIR="${REPO_DIR}/logs"
BACKUP_RETAIN_DAYS=7
HEALTH_TIMEOUT=120
CRON_SCHEDULE="0 3 * * 0"

# ── 运行时 ──────────────────────────────────────────────────────────────────

TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/upgrade_${TS}.log"
BACKUP_DIR=""
OLD_GIT_SHA=""
ROLLBACK_DONE=false

# ── 工具 ────────────────────────────────────────────────────────────────────

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_ok()   { log "OK:    $*"; }
log_warn() { log "WARN:  $*"; }
log_err()  { log "ERROR: $*"; }
die()      { log_err "$*"; exit 1; }

read_env() {
    local key="$1" default="${2:-}"
    local val
    val=$(grep "^${key}=" "${REPO_DIR}/.env" 2>/dev/null | cut -d= -f2-)
    echo "${val:-$default}"
}

# ── 预检 ────────────────────────────────────────────────────────────────────

preflight() {
    log "── 预检 ──"
    [[ -f "${REPO_DIR}/Makefile" ]]                          || die "找不到 Makefile，请在仓库根目录执行"
    [[ -f "${REPO_DIR}/docker-compose.selfhost.yml" ]]       || die "找不到 docker-compose.selfhost.yml"
    [[ -f "${REPO_DIR}/.env" ]]                              || die "找不到 .env（请先执行 make selfhost）"
    docker info &>/dev/null                                  || die "Docker daemon 未运行"
    git -C "$REPO_DIR" rev-parse --is-inside-work-tree &>/dev/null || die "不是 git 仓库"

    # 磁盘空间 ≥ 5GB
    local avail_gb=$(( $(df -k "$REPO_DIR" | awk 'NR==2{print $4}') / 1024 / 1024 ))
    [[ $avail_gb -ge 5 ]] || die "磁盘空间不足: ${avail_gb}GB"

    # 未提交的本地修改
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
        log_warn "仓库有未提交的修改，升级前会自动 stash"
    fi

    log_ok "预检通过 (磁盘 ${avail_gb}GB 可用)"
}

# ── 备份 ────────────────────────────────────────────────────────────────────

backup() {
    log "── 备份 ──"
    BACKUP_DIR="${BACKUP_ROOT}/${TS}"
    mkdir -p "$BACKUP_DIR"

    # 记录当前 git 版本
    OLD_GIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
    echo "$OLD_GIT_SHA" > "${BACKUP_DIR}/git-sha.txt"
    log "  git SHA: ${OLD_GIT_SHA:0:12}"

    # .env
    cp "${REPO_DIR}/.env" "${BACKUP_DIR}/.env"
    log_ok ".env"

    # PostgreSQL pg_dump
    local pg_c
    pg_c=$(docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" ps -q postgres 2>/dev/null || true)
    if [[ -n "$pg_c" ]]; then
        local pg_user pg_db
        pg_user=$(read_env POSTGRES_USER multica)
        pg_db=$(read_env POSTGRES_DB multica)
        docker exec "$pg_c" pg_dump -U "$pg_user" -d "$pg_db" \
            --format=custom --compress=6 > "${BACKUP_DIR}/db.dump" 2>>"$LOG_FILE"
        log_ok "数据库 ($(du -sh "${BACKUP_DIR}/db.dump" | awk '{print $1}'))"
    else
        log_warn "PostgreSQL 未运行，跳过数据库备份"
    fi

    # uploads 卷
    local vol
    vol=$(docker volume ls --format '{{.Name}}' | grep 'backend_uploads' | head -1 || true)
    if [[ -n "$vol" ]]; then
        mkdir -p "${BACKUP_DIR}/uploads"
        docker run --rm -v "${vol}:/src:ro" -v "${BACKUP_DIR}/uploads:/dst" \
            alpine:latest cp -a /src/. /dst/ 2>>"$LOG_FILE"
        log_ok "uploads 卷"
    fi
}

# ── 升级 ────────────────────────────────────────────────────────────────────

upgrade() {
    log "── 升级 ──"

    # stash 本地已跟踪文件的修改（不包含 untracked 文件如 backups/）
    local stashed=false
    local changes
    changes=$(git -C "$REPO_DIR" diff --name-only 2>/dev/null || true)
    if [[ -n "$changes" ]]; then
        if git -C "$REPO_DIR" stash push -m "auto-stash before upgrade ${TS}" 2>&1 | tee -a "$LOG_FILE"; then
            stashed=true
            log "已 stash 本地修改"
        fi
    fi

    # git pull（拉最新代码）
    log "git pull..."
    if ! git -C "$REPO_DIR" pull --ff-only 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "git pull 失败，继续使用本地代码执行 make selfhost"
    fi

    local new_sha
    new_sha=$(git -C "$REPO_DIR" rev-parse HEAD)
    if [[ "$OLD_GIT_SHA" != "$new_sha" ]]; then
        log "代码更新: ${OLD_GIT_SHA:0:12} → ${new_sha:0:12}"
    else
        log "代码未变 (${new_sha:0:12})，仍执行 make selfhost 拉取最新镜像"
    fi

    # make selfhost（复用已有 .env，拉最新镜像，重启服务）
    log "make selfhost..."
    if ! make -C "$REPO_DIR" selfhost 2>&1 | tee -a "$LOG_FILE"; then
        log_err "make selfhost 失败"
        [[ "$stashed" == "true" ]] && git -C "$REPO_DIR" stash pop 2>/dev/null || true
        return 1
    fi

    # 恢复 stash
    [[ "$stashed" == "true" ]] && { git -C "$REPO_DIR" stash pop 2>/dev/null || log_warn "stash pop 失败，请手动处理"; }
}

# ── 健康检查 ─────────────────────────────────────────────────────────────────

health_check() {
    log "── 健康检查 (超时 ${HEALTH_TIMEOUT}s) ──"
    local elapsed=0 pg=false be=false fe=false

    while [[ $elapsed -lt $HEALTH_TIMEOUT ]]; do
        # PostgreSQL
        if [[ "$pg" == "false" ]]; then
            local c
            c=$(docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" ps -q postgres 2>/dev/null || true)
            [[ -n "$c" && "$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null)" == "healthy" ]] && { pg=true; log_ok "PostgreSQL ✓"; }
        fi
        # Backend
        if [[ "$pg" == "true" && "$be" == "false" ]]; then
            local code
            code=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:$(read_env BACKEND_PORT 8080)/health" 2>/dev/null || echo 000)
            [[ "$code" =~ ^(200|301|302)$ ]] && { be=true; log_ok "Backend ✓ (HTTP $code)"; }
        fi
        # Frontend
        if [[ "$be" == "true" && "$fe" == "false" ]]; then
            local code
            code=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:$(read_env FRONTEND_PORT 3000)" 2>/dev/null || echo 000)
            [[ "$code" =~ ^(200|301|302|307)$ ]] && { fe=true; log_ok "Frontend ✓ (HTTP $code)"; }
        fi
        [[ "$pg" == "true" && "$be" == "true" && "$fe" == "true" ]] && return 0
        sleep 5; elapsed=$((elapsed + 5))
    done

    log_err "健康检查超时 (PG:${pg} BE:${be} FE:${fe})"
    return 1
}

# ── 回滚 ────────────────────────────────────────────────────────────────────

rollback() {
    log "── 回滚 ──"
    ROLLBACK_DONE=true
    [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]] && { log_err "无可用备份，无法自动回滚"; return 1; }

    # 停服务
    docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" down 2>&1 | tee -a "$LOG_FILE" || true

    # 恢复 git 版本
    local old_sha
    old_sha=$(cat "${BACKUP_DIR}/git-sha.txt")
    log "git checkout ${old_sha:0:12}..."
    git -C "$REPO_DIR" checkout "$old_sha" 2>&1 | tee -a "$LOG_FILE" || {
        log_err "git checkout 失败"
        return 1
    }

    # 恢复 .env
    cp "${BACKUP_DIR}/.env" "${REPO_DIR}/.env"
    log_ok ".env 已恢复"

    # 恢复数据库
    if [[ -f "${BACKUP_DIR}/db.dump" ]]; then
        log "恢复数据库..."
        docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" up -d postgres 2>&1 | tee -a "$LOG_FILE"
        sleep 8

        local pg_c pg_user pg_db
        pg_c=$(docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" ps -q postgres 2>/dev/null || true)
        pg_user=$(read_env POSTGRES_USER multica)
        pg_db=$(read_env POSTGRES_DB multica)

        if [[ -n "$pg_c" ]]; then
            docker exec "$pg_c" psql -U "$pg_user" -d postgres \
                -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${pg_db}' AND pid <> pg_backend_pid();" 2>>"$LOG_FILE" || true
            docker exec "$pg_c" psql -U "$pg_user" -d postgres \
                -c "DROP DATABASE IF EXISTS \"${pg_db}\";" 2>>"$LOG_FILE"
            docker exec "$pg_c" psql -U "$pg_user" -d postgres \
                -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" 2>>"$LOG_FILE"
            docker exec -i "$pg_c" pg_restore -U "$pg_user" -d "$pg_db" \
                --no-owner --no-privileges < "${BACKUP_DIR}/db.dump" 2>>"$LOG_FILE" || true
            log_ok "数据库已恢复"
        else
            log_err "PostgreSQL 启动失败，请手动恢复: pg_restore -U multica -d multica < ${BACKUP_DIR}/db.dump"
        fi
    fi

    # 恢复 uploads
    if [[ -d "${BACKUP_DIR}/uploads" && "$(ls -A "${BACKUP_DIR}/uploads" 2>/dev/null)" ]]; then
        local vol
        vol=$(docker volume ls --format '{{.Name}}' | grep 'backend_uploads' | head -1 || true)
        [[ -n "$vol" ]] && docker run --rm -v "${vol}:/dst" -v "${BACKUP_DIR}/uploads:/src:ro" \
            alpine:latest sh -c 'rm -rf /dst/* 2>/dev/null; cp -a /src/. /dst/' 2>>"$LOG_FILE"
        log_ok "uploads 已恢复"
    fi

    # 用旧版本重新启动
    log "make selfhost (旧版本)..."
    make -C "$REPO_DIR" selfhost 2>&1 | tee -a "$LOG_FILE" || {
        log_err "回滚后 make selfhost 失败，请手动排查"
        log_err "  备份目录: ${BACKUP_DIR}"
        return 1
    }

    # 回到之前的分支
    local branch
    branch=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
    git -C "$REPO_DIR" checkout "$branch" 2>/dev/null || true

    sleep 5
    health_check && log_ok "回滚成功，服务已恢复正常" || log_err "回滚后健康检查未通过，请手动排查"

    log "备份保留在: ${BACKUP_DIR}"
}

# ── 清理旧备份 ──────────────────────────────────────────────────────────────

cleanup() {
    local count=0
    while IFS= read -r d; do
        [[ -d "$d" && "$d" != "$BACKUP_DIR" ]] && { rm -rf "$d"; count=$((count + 1)); }
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime "+${BACKUP_RETAIN_DAYS}" 2>/dev/null)
    [[ $count -gt 0 ]] && log "清理了 ${count} 个旧备份"
}

# ── Cron ────────────────────────────────────────────────────────────────────

install_cron() {
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    local cmd="${CRON_SCHEDULE} cd ${REPO_DIR} && bash ${script_path} >> ${LOG_DIR}/cron.log 2>&1"
    crontab -l 2>/dev/null | grep -vF "$(basename "$0")" | { cat; echo "$cmd"; } | crontab -
    log_ok "定时任务已安装: ${CRON_SCHEDULE}"
}

uninstall_cron() {
    crontab -l 2>/dev/null | grep -vF "$(basename "$0")" | crontab -
    log_ok "定时任务已卸载"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$LOG_DIR" "$BACKUP_ROOT"

    case "${1:-}" in
        --dry-run)
            preflight
            OLD_GIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
            log "当前版本: ${OLD_GIT_SHA:0:12}"
            git -C "$REPO_DIR" fetch origin 2>/dev/null
            local remote_sha
            remote_sha=$(git -C "$REPO_DIR" rev-parse origin/HEAD 2>/dev/null || git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null || echo "")
            if [[ -n "$remote_sha" && "$OLD_GIT_SHA" != "$remote_sha" ]]; then
                log "有新版本可用: ${remote_sha:0:12}"
            else
                log "已是最新版本"
            fi
            exit 0 ;;
        --install-cron)   install_cron; exit 0 ;;
        --uninstall-cron) uninstall_cron; exit 0 ;;
        -h|--help)
            echo "用法: bash $0 [--dry-run|--install-cron|--uninstall-cron]"
            exit 0 ;;
    esac

    log "════════════════════════════════════════════════"
    log "  Multica 升级 - $(date '+%Y-%m-%d %H:%M:%S')"
    log "════════════════════════════════════════════════"

    preflight
    backup

    if upgrade; then
        if health_check; then
            log_ok "升级成功"
            cleanup
        else
            log_err "健康检查未通过，触发回滚..."
            rollback
            exit 1
        fi
    else
        log_err "升级过程出错，触发回滚..."
        rollback
        exit 1
    fi

    log "════════════════════════════════════════════════"
}

cleanup_on_exit() {
    _rc=$?
    if [[ $_rc -ne 0 && "$ROLLBACK_DONE" == "false" && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        log_err "异常退出 (code=$_rc)，触发回滚..."
        rollback
    fi
}
trap cleanup_on_exit EXIT

main "$@"
