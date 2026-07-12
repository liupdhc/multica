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

    # 保存当前运行的镜像 ID（回滚时需要精确恢复旧镜像）
    local compose_file="${REPO_DIR}/docker-compose.selfhost.yml"
    (
        echo "BACKEND_IMAGE_ID=$(docker inspect --format='{{.Id}}' \
            "$(docker compose -f "$compose_file" ps -q backend 2>/dev/null)" 2>/dev/null || echo "")"
        echo "FRONTEND_IMAGE_ID=$(docker inspect --format='{{.Id}}' \
            "$(docker compose -f "$compose_file" ps -q frontend 2>/dev/null)" 2>/dev/null || echo "")"
        echo "POSTGRES_IMAGE_ID=$(docker inspect --format='{{.Id}}' \
            "$(docker compose -f "$compose_file" ps -q postgres 2>/dev/null)" 2>/dev/null || echo "")"
    ) > "${BACKUP_DIR}/image-ids.env"
    log_ok "镜像 ID ($(cat "${BACKUP_DIR}/image-ids.env" | grep -c 'sha256' || echo 0) 个)"
}

# ── 拉取单个镜像（重试 + ghcr.io 代理回退） ────────────────────────────────

# 执行 docker pull，输出同时写终端和日志文件
_do_pull() {
    local image="$1"
    local pull_log
    pull_log=$(mktemp)

    # docker pull 输出同时写终端和临时文件
    docker pull "$image" 2>&1 | tee "$pull_log"
    local rc=${PIPESTATUS[0]}

    # 检查是否是 "已是最新"
    if grep -q "Image is up to date\|Already exists\|Downloaded newer image\|Pull complete" "$pull_log" 2>/dev/null; then
        if [[ $rc -eq 0 ]]; then
            rm -f "$pull_log"
            return 0
        fi
    fi

    # 失败时把 docker 实际错误记入日志
    if [[ $rc -ne 0 ]]; then
        local docker_err
        docker_err=$(tail -3 "$pull_log" | tr '\n' ' ')
        log "  docker 错误: ${docker_err}" >> "$LOG_FILE"
    fi

    rm -f "$pull_log"
    return $rc
}

# ghcr.io 镜像走代理拉取，然后 tag 回原名
_pull_via_mirror() {
    local original="$1" mirror="$2"
    local mirrored="${original/ghcr.io/$mirror}"
    log "  尝试代理: ${mirror} ..."
    if _do_pull "$mirrored"; then
        docker tag "$mirrored" "$original" 2>/dev/null
        docker rmi "$mirrored" 2>/dev/null || true
        return 0
    fi
    return 1
}

pull_image() {
    local image="$1"
    local max_retry=3

    for attempt in $(seq 1 $max_retry); do
        log "  拉取 ${image} (第 ${attempt}/${max_retry} 次)..."

        # 直连
        if _do_pull "$image"; then
            log_ok "${image}"
            return 0
        fi

        log_warn "直连失败"

        # ghcr.io 走代理
        if [[ "$image" == ghcr.io/* ]]; then
            local custom_mirror
            custom_mirror=$(read_env GITHUB_MIRROR "")

            if [[ -n "$custom_mirror" ]]; then
                if _pull_via_mirror "$image" "$custom_mirror"; then
                    log_ok "${image} (via ${custom_mirror})"
                    return 0
                fi
                log_warn "代理 ${custom_mirror} 也失败"
            else
                local mirrors=("ghcr.dockerproxy.com" "ghcr.nju.edu.cn")
                for m in "${mirrors[@]}"; do
                    if _pull_via_mirror "$image" "$m"; then
                        log_ok "${image} (via ${m})"
                        echo "GITHUB_MIRROR=$m" >> "${REPO_DIR}/.env"
                        log "  已将 ${m} 写入 .env"
                        return 0
                    fi
                done
                log_warn "所有代理均失败"
            fi
        fi

        # 重试等待（指数退避：30s, 60s, 120s）
        if [[ $attempt -lt $max_retry ]]; then
            local wait=$(( 30 * (2 ** (attempt - 1)) ))
            log "  ${wait}s 后重试..."
            sleep "$wait"
        fi
    done

    log_err "拉取 ${image} 失败（直连 + 代理均不可用）"
    log_err "  手动配置代理: 在 .env 中添加 GITHUB_MIRROR=你的镜像站地址"
    return 1
}

# ── 升级 ────────────────────────────────────────────────────────────────────

upgrade() {
    log "── 升级 ──"

    # 有本地修改时先 stash 保护，升级后不自动 pop（保留在 stash 列表中，需要时手动恢复）
    if [[ -n "$(git -C "$REPO_DIR" diff --name-only 2>/dev/null || true)" ]]; then
        git -C "$REPO_DIR" stash push -m "auto-stash before upgrade ${TS}" 2>&1 | tee -a "$LOG_FILE" || true
        log "本地修改已 stash（升级后如需恢复: git stash pop）"
    fi

    # git pull（拉最新代码）
    log "git pull..."
    if ! git -C "$REPO_DIR" pull --ff-only 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "git pull 失败，继续使用本地代码"
    fi

    local new_sha
    new_sha=$(git -C "$REPO_DIR" rev-parse HEAD)
    if [[ "$OLD_GIT_SHA" != "$new_sha" ]]; then
        log "代码更新: ${OLD_GIT_SHA:0:12} → ${new_sha:0:12}"
    else
        log "代码未变 (${new_sha:0:12})，继续拉取最新镜像"
    fi

    # 读取镜像名称
    local be_img fe_img pg_img tag
    be_img=$(read_env MULTICA_BACKEND_IMAGE "ghcr.io/multica-ai/multica-backend")
    fe_img=$(read_env MULTICA_WEB_IMAGE "ghcr.io/multica-ai/multica-web")
    pg_img="pgvector/pgvector:pg17"
    tag=$(read_env MULTICA_IMAGE_TAG "latest")

    # 逐个拉镜像（带超时 + 重试，阿里云到 ghcr.io 网络不稳定）
    log "── 拉取镜像 ──"
    local pull_failed=false
    pull_image "${be_img}:${tag}" || pull_failed=true
    pull_image "${fe_img}:${tag}" || pull_failed=true
    # postgres 镜像一般不需要更新，但也拉一下确保最新
    pull_image "${pg_img}"        || log_warn "postgres 镜像拉取失败，使用本地缓存"

    if [[ "$pull_failed" == "true" ]]; then
        log_err "应用镜像拉取失败，请检查网络或配置 Docker 镜像加速器"
        log_err "  可在 /etc/docker/daemon.json 中添加 registry-mirrors"
        return 1
    fi

    # 启动/重启服务（镜像已就绪，不再走 make selfhost 的 pull 步骤）
    log "── 启动服务 ──"
    docker compose -f "${REPO_DIR}/docker-compose.selfhost.yml" up -d 2>&1 | tee -a "$LOG_FILE" || {
        log_err "docker compose up 失败"
        return 1
    }
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

    # 用旧版本重新启动（不 pull，使用备份的旧镜像 ID）
    log "用旧镜像重启服务..."
    local compose_file="${REPO_DIR}/docker-compose.selfhost.yml"

    # 将旧镜像 ID 重新 tag 为 compose 期望的名称，防止 pull 到新版本
    if [[ -f "${BACKUP_DIR}/image-ids.env" ]]; then
        source "${BACKUP_DIR}/image-ids.env"
        local be_tag fe_tag pg_tag
        be_tag=$(read_env MULTICA_BACKEND_IMAGE "ghcr.io/multica-ai/multica-backend"):$(read_env MULTICA_IMAGE_TAG "latest")
        fe_tag=$(read_env MULTICA_WEB_IMAGE "ghcr.io/multica-ai/multica-web"):$(read_env MULTICA_IMAGE_TAG "latest")
        pg_tag="pgvector/pgvector:pg17"

        if [[ -n "$BACKEND_IMAGE_ID" ]];  then docker tag "$BACKEND_IMAGE_ID"  "$be_tag" 2>/dev/null || true; fi
        if [[ -n "$FRONTEND_IMAGE_ID" ]]; then docker tag "$FRONTEND_IMAGE_ID" "$fe_tag" 2>/dev/null || true; fi
        if [[ -n "$POSTGRES_IMAGE_ID" ]]; then docker tag "$POSTGRES_IMAGE_ID" "$pg_tag" 2>/dev/null || true; fi
        log_ok "已将旧镜像 ID 重新 tag 为 ${be_tag##*/} / ${fe_tag##*/}"
    fi

    docker compose -f "$compose_file" up -d 2>&1 | tee -a "$LOG_FILE" || {
        log_err "回滚后 docker compose up 失败，请手动排查"
        log_err "  备份目录: ${BACKUP_DIR}"
        return 1
    }

    # 回到之前的分支
    local branch
    branch=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
    git -C "$REPO_DIR" checkout "$branch" 2>/dev/null || true

    sleep 5
    if health_check; then
        log_ok "回滚成功，服务已恢复正常"
    else
        log_err "回滚后健康检查未通过，请手动排查"
    fi

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
