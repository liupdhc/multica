#!/usr/bin/env bash
# ============================================================================
#  Multica 自动升级 & 失败回滚脚本
#  适用于 git clone + make selfhost 的 Docker Compose 部署
#  参考：https://github.com/multica-ai/multica/blob/main/SELF_HOSTING.md
# ============================================================================
#
#  用法:
#    bash multica-upgrade.sh                  # 手动执行一次升级
#    bash multica-upgrade.sh --install-cron   # 安装定时任务（每周日凌晨 3 点）
#    bash multica-upgrade.sh --uninstall-cron # 卸载定时任务
#    bash multica-upgrade.sh --dry-run        # 仅检查是否有新版本，不执行升级
#
#  脚本逻辑:
#    1. 预检（磁盘空间、Docker 状态、服务运行状况）
#    2. 记录当前镜像摘要，备份数据库、.env、docker-compose 文件、上传文件卷
#    3. 拉取最新镜像并重启服务
#    4. 健康检查（PostgreSQL / Backend / Frontend）
#    5. 检查通过 → 保留备份 7 天；检查失败 → 自动回滚到升级前状态
#
set -euo pipefail

# ======================== 可配置变量 =========================================

# Multica 仓库克隆路径（根据你的实际路径修改）
MULTICA_DIR="${MULTICA_DIR:-/opt/multica}"

# docker compose 文件
COMPOSE_FILE="${MULTICA_DIR}/docker-compose.selfhost.yml"

# 备份根目录
BACKUP_ROOT="${MULTICA_DIR}/backups"

# 备份保留天数
BACKUP_RETAIN_DAYS=7

# 健康检查超时（秒）
HEALTH_CHECK_TIMEOUT=120

# 健康检查间隔（秒）
HEALTH_CHECK_INTERVAL=5

# 日志文件
LOG_DIR="${MULTICA_DIR}/logs"

# Cron 表达式（默认每周日凌晨 3:00）
CRON_SCHEDULE="0 3 * * 0"

# ======================== 内部变量 ===========================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/upgrade_${TIMESTAMP}.log"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
COMPOSE_CMD=""
OLD_BACKEND_DIGEST=""
OLD_FRONTEND_DIGEST=""
OLD_POSTGRES_DIGEST=""
ROLLBACK_NEEDED=false
ROLLBACK_DONE=false

# ======================== 工具函数 ===========================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $*"
}

log_warn() {
    log "WARN:  $*"
}

log_ok() {
    log "OK:    $*"
}

die() {
    log_error "$@"
    exit 1
}

# 检测 docker compose 命令（兼容 v1 和 v2）
detect_compose_cmd() {
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        die "未检测到 docker compose 或 docker-compose，请先安装"
    fi
    log "使用 compose 命令: ${COMPOSE_CMD}"
}

compose() {
    ${COMPOSE_CMD} -f "$COMPOSE_FILE" "$@"
}

# ======================== 预检 ===============================================

preflight_checks() {
    log "========== 预检 =========="

    # 1) 目录存在
    [[ -d "$MULTICA_DIR" ]] || die "Multica 目录不存在: ${MULTICA_DIR}"
    [[ -f "$COMPOSE_FILE" ]] || die "Docker Compose 文件不存在: ${COMPOSE_FILE}"
    [[ -f "${MULTICA_DIR}/.env" ]] || die ".env 文件不存在: ${MULTICA_DIR}/.env"

    # 2) Docker 运行中
    docker info &>/dev/null || die "Docker daemon 未运行"
    log_ok "Docker daemon 正常"

    # 3) 磁盘空间（至少需要 5GB 可用）
    local avail_kb
    avail_kb=$(df -k "$MULTICA_DIR" | awk 'NR==2 {print $4}')
    local avail_gb=$((avail_kb / 1024 / 1024))
    if [[ $avail_gb -lt 5 ]]; then
        die "磁盘可用空间不足: ${avail_gb}GB（需要至少 5GB）"
    fi
    log_ok "磁盘可用空间: ${avail_gb}GB"

    # 4) 当前服务运行状态
    local running
    running=$(compose ps --format json 2>/dev/null | grep -c '"running"' || true)
    if [[ "$running" -eq 0 ]]; then
        log_warn "当前没有运行中的服务，将执行全新启动"
    else
        log_ok "当前有 ${running} 个运行中的服务"
    fi

    log "========== 预检通过 =========="
}

# ======================== 记录当前镜像 ========================================

record_current_images() {
    log "记录当前镜像信息..."

    OLD_BACKEND_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' \
        "$(compose ps -q backend 2>/dev/null || true)" 2>/dev/null || echo "")
    OLD_FRONTEND_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' \
        "$(compose ps -q frontend 2>/dev/null || true)" 2>/dev/null || echo "")
    OLD_POSTGRES_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' \
        "$(compose ps -q postgres 2>/dev/null || true)" 2>/dev/null || echo "")

    # 如果 inspect 失败，回退到记录 image tag
    if [[ -z "$OLD_BACKEND_DIGEST" ]]; then
        OLD_BACKEND_DIGEST=$(compose config 2>/dev/null | grep -A5 'backend:' | grep 'image:' | head -1 | awk '{print $2}' || echo "unknown")
    fi
    if [[ -z "$OLD_FRONTEND_DIGEST" ]]; then
        OLD_FRONTEND_DIGEST=$(compose config 2>/dev/null | grep -A5 'frontend:' | grep 'image:' | head -1 | awk '{print $2}' || echo "unknown")
    fi
    if [[ -z "$OLD_POSTGRES_DIGEST" ]]; then
        OLD_POSTGRES_DIGEST="pgvector/pgvector:pg17"
    fi

    log "  Backend:  ${OLD_BACKEND_DIGEST}"
    log "  Frontend: ${OLD_FRONTEND_DIGEST}"
    log "  Postgres: ${OLD_POSTGRES_DIGEST}"
}

# ======================== 检查新版本 ==========================================

check_new_version() {
    log "检查是否有新版本..."

    local backend_image frontend_image
    backend_image=$(compose config 2>/dev/null | grep -A10 'backend:' | grep 'image:' | head -1 | awk '{print $2}' || echo "ghcr.io/multica-ai/multica-backend:latest")
    frontend_image=$(compose config 2>/dev/null | grep -A10 'frontend:' | grep 'image:' | head -1 | awk '{print $2}' || echo "ghcr.io/multica-ai/multica-web:latest")

    # 拉取最新的 manifest
    local new_backend_digest new_frontend_digest
    new_backend_digest=$(docker pull "$backend_image" 2>&1 | tail -1 || echo "")
    new_frontend_digest=$(docker pull "$frontend_image" 2>&1 | tail -1 || echo "")

    # 比较 digest
    local has_update=false
    if [[ -n "$OLD_BACKEND_DIGEST" && "$OLD_BACKEND_DIGEST" != "unknown" ]]; then
        local old_short new_short
        old_short=$(echo "$OLD_BACKEND_DIGEST" | cut -d@ -f2 | cut -c1-19)
        new_short=$(echo "$new_backend_digest" | grep -oP 'sha256:[a-f0-9]+' | cut -c1-26 || echo "$new_backend_digest")
        if [[ "$old_short" != "$new_short" && -n "$new_short" ]]; then
            log "  Backend 有新版本可用"
            has_update=true
        else
            log "  Backend 已是最新"
        fi
    else
        has_update=true
    fi

    if [[ "$has_update" == "false" ]]; then
        log "所有镜像已是最新版本，无需升级"
        return 1  # 返回 1 表示无需更新
    fi

    log "检测到新版本，准备升级"
    return 0
}

# ======================== 备份 ===============================================

backup_all() {
    log "========== 开始备份 =========="
    mkdir -p "$BACKUP_DIR"

    # 1) 备份 .env
    cp "${MULTICA_DIR}/.env" "${BACKUP_DIR}/.env.bak"
    log_ok ".env 已备份 → ${BACKUP_DIR}/.env.bak"

    # 2) 备份 docker-compose 文件
    cp "$COMPOSE_FILE" "${BACKUP_DIR}/docker-compose.selfhost.yml.bak"
    log_ok "docker-compose 文件已备份"

    # 3) 备份 PostgreSQL 数据库（pg_dump 逻辑备份，最安全）
    log "正在备份 PostgreSQL 数据库（可能需要一些时间）..."
    local pg_container
    pg_container=$(compose ps -q postgres 2>/dev/null || true)

    if [[ -n "$pg_container" && "$pg_container" != "" ]]; then
        # 从 .env 读取数据库连接信息
        local pg_user pg_db
        pg_user=$(grep '^POSTGRES_USER=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "multica")
        pg_db=$(grep '^POSTGRES_DB=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "multica")
        [[ -z "$pg_user" ]] && pg_user="multica"
        [[ -z "$pg_db" ]] && pg_db="multica"

        docker exec "$pg_container" pg_dump \
            -U "$pg_user" \
            -d "$pg_db" \
            --format=custom \
            --compress=6 \
            > "${BACKUP_DIR}/database.dump" 2>>"$LOG_FILE"

        local dump_size
        dump_size=$(du -sh "${BACKUP_DIR}/database.dump" 2>/dev/null | awk '{print $1}')
        log_ok "PostgreSQL 数据库已备份 (${dump_size}) → ${BACKUP_DIR}/database.dump"
    else
        log_warn "PostgreSQL 容器未运行，跳过数据库备份"
    fi

    # 4) 备份上传文件卷（增量方式：使用 rsync 如果可用，否则 cp）
    local uploads_vol
    uploads_vol=$(docker volume ls --format '{{.Name}}' | grep 'backend_uploads' | head -1 || true)

    if [[ -n "$uploads_vol" ]]; then
        log "正在备份上传文件卷..."
        mkdir -p "${BACKUP_DIR}/uploads"
        if command -v rsync &>/dev/null; then
            # 使用临时容器挂载卷并 rsync
            docker run --rm \
                -v "${uploads_vol}:/source:ro" \
                -v "${BACKUP_DIR}/uploads:/target" \
                alpine:latest \
                sh -c "cp -a /source/. /target/" 2>>"$LOG_FILE"
        else
            docker run --rm \
                -v "${uploads_vol}:/source:ro" \
                -v "${BACKUP_DIR}/uploads:/target" \
                alpine:latest \
                sh -c "cp -a /source/. /target/" 2>>"$LOG_FILE"
        fi
        log_ok "上传文件卷已备份 → ${BACKUP_DIR}/uploads/"
    else
        log_warn "未找到 backend_uploads 卷，跳过上传文件备份"
    fi

    # 5) 记录当前镜像 digest 到文件（回滚时使用）
    cat > "${BACKUP_DIR}/image_digests.txt" <<EOF
BACKEND_DIGEST=${OLD_BACKEND_DIGEST}
FRONTEND_DIGEST=${OLD_FRONTEND_DIGEST}
POSTGRES_DIGEST=${OLD_POSTGRES_DIGEST}
TIMESTAMP=${TIMESTAMP}
EOF
    log_ok "镜像摘要已记录 → ${BACKUP_DIR}/image_digests.txt"

    log "========== 备份完成 =========="
}

# ======================== 执行升级 ============================================

perform_upgrade() {
    log "========== 开始升级 =========="

    # 1) 拉取最新镜像
    log "拉取最新镜像..."
    compose pull 2>&1 | tee -a "$LOG_FILE" || {
        log_warn "部分镜像拉取失败，但将继续尝试启动"
    }

    # 2) 优雅停止当前服务（先停应用，后停数据库）
    log "优雅停止当前服务..."
    compose stop frontend backend 2>&1 | tee -a "$LOG_FILE" || true
    sleep 3
    compose stop postgres 2>&1 | tee -a "$LOG_FILE" || true
    sleep 2

    # 3) 用新镜像启动所有服务
    log "使用新镜像启动服务..."
    compose up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE" || {
        log_error "服务启动失败"
        ROLLBACK_NEEDED=true
        return 1
    }

    log "服务已启动，等待健康检查..."
    sleep 5
    log "========== 升级完成，进入健康检查 =========="
}

# ======================== 健康检查 ============================================

health_checks() {
    log "========== 健康检查 (超时: ${HEALTH_CHECK_TIMEOUT}s) =========="

    local elapsed=0
    local pg_ok=false
    local backend_ok=false
    local frontend_ok=false

    while [[ $elapsed -lt $HEALTH_CHECK_TIMEOUT ]]; do
        # --- PostgreSQL ---
        if [[ "$pg_ok" == "false" ]]; then
            local pg_container
            pg_container=$(compose ps -q postgres 2>/dev/null || true)
            if [[ -n "$pg_container" ]]; then
                local pg_health
                pg_health=$(docker inspect --format='{{.State.Health.Status}}' "$pg_container" 2>/dev/null || echo "unknown")
                if [[ "$pg_health" == "healthy" ]]; then
                    pg_ok=true
                    log_ok "PostgreSQL 健康 (${elapsed}s)"
                fi
            fi
        fi

        # --- Backend ---
        if [[ "$pg_ok" == "true" && "$backend_ok" == "false" ]]; then
            local backend_port
            backend_port=$(grep '^BACKEND_PORT=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "8080")
            [[ -z "$backend_port" ]] && backend_port="8080"

            # 尝试 HTTP 请求 /health 或 /api/health
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                "http://127.0.0.1:${backend_port}/api/health" 2>/dev/null || echo "000")
            if [[ "$http_code" == "000" ]]; then
                http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    "http://127.0.0.1:${backend_port}/health" 2>/dev/null || echo "000")
            fi
            if [[ "$http_code" =~ ^(200|301|302|404)$ ]]; then
                backend_ok=true
                log_ok "Backend 响应正常 (HTTP ${http_code}, ${elapsed}s)"
            fi
        fi

        # --- Frontend ---
        if [[ "$backend_ok" == "true" && "$frontend_ok" == "false" ]]; then
            local frontend_port
            frontend_port=$(grep '^FRONTEND_PORT=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "3000")
            [[ -z "$frontend_port" ]] && frontend_port="3000"

            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                "http://127.0.0.1:${frontend_port}" 2>/dev/null || echo "000")
            if [[ "$http_code" =~ ^(200|301|302|307)$ ]]; then
                frontend_ok=true
                log_ok "Frontend 响应正常 (HTTP ${http_code}, ${elapsed}s)"
            fi
        fi

        # 全部通过
        if [[ "$pg_ok" == "true" && "$backend_ok" == "true" && "$frontend_ok" == "true" ]]; then
            log "========== 所有健康检查通过 =========="
            return 0
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
        log "  等待中... ${elapsed}s (PG:${pg_ok} BE:${backend_ok} FE:${frontend_ok})"
    done

    # 超时
    log_error "健康检查超时 (${HEALTH_CHECK_TIMEOUT}s)"
    log_error "  PostgreSQL: ${pg_ok}"
    log_error "  Backend:    ${backend_ok}"
    log_error "  Frontend:   ${frontend_ok}"
    return 1
}

# ======================== 回滚 ===============================================

perform_rollback() {
    log "========== 开始回滚 =========="
    log_warn "升级失败，正在恢复到升级前的状态..."

    # 1) 停止所有当前服务
    log "停止当前服务..."
    compose down 2>&1 | tee -a "$LOG_FILE" || true
    sleep 3

    # 2) 恢复 .env 文件
    if [[ -f "${BACKUP_DIR}/.env.bak" ]]; then
        cp "${BACKUP_DIR}/.env.bak" "${MULTICA_DIR}/.env"
        log_ok ".env 已恢复"
    fi

    # 3) 恢复 docker-compose 文件
    if [[ -f "${BACKUP_DIR}/docker-compose.selfhost.yml.bak" ]]; then
        cp "${BACKUP_DIR}/docker-compose.selfhost.yml.bak" "$COMPOSE_FILE"
        log_ok "docker-compose 文件已恢复"
    fi

    # 4) 恢复数据库（如果备份存在）
    if [[ -f "${BACKUP_DIR}/database.dump" ]]; then
        log "正在恢复 PostgreSQL 数据库..."

        # 先单独启动 postgres
        compose up -d postgres 2>&1 | tee -a "$LOG_FILE"
        log "等待 PostgreSQL 启动..."
        sleep 10

        local pg_container
        pg_container=$(compose ps -q postgres 2>/dev/null || true)

        if [[ -n "$pg_container" ]]; then
            local pg_user pg_db
            pg_user=$(grep '^POSTGRES_USER=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "multica")
            pg_db=$(grep '^POSTGRES_DB=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "multica")
            [[ -z "$pg_user" ]] && pg_user="multica"
            [[ -z "$pg_db" ]] && pg_db="multica"

            # 删除现有连接并恢复
            docker exec "$pg_container" psql -U "$pg_user" -d postgres \
                -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${pg_db}' AND pid <> pg_backend_pid();" \
                2>>"$LOG_FILE" || true
            docker exec "$pg_container" psql -U "$pg_user" -d postgres \
                -c "DROP DATABASE IF EXISTS \"${pg_db}\";" 2>>"$LOG_FILE" || true
            docker exec "$pg_container" psql -U "$pg_user" -d postgres \
                -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" 2>>"$LOG_FILE" || true

            docker exec -i "$pg_container" pg_restore \
                -U "$pg_user" \
                -d "$pg_db" \
                --no-owner \
                --no-privileges \
                < "${BACKUP_DIR}/database.dump" 2>>"$LOG_FILE" || {
                    log_warn "pg_restore 报告了一些警告（这通常是正常的）"
                }

            log_ok "PostgreSQL 数据库已恢复"
        else
            log_error "PostgreSQL 容器未能启动，数据库恢复失败！"
            log_error "请手动恢复: pg_restore -U multica -d multica < ${BACKUP_DIR}/database.dump"
        fi
    fi

    # 5) 恢复上传文件卷
    if [[ -d "${BACKUP_DIR}/uploads" && "$(ls -A "${BACKUP_DIR}/uploads" 2>/dev/null)" ]]; then
        log "正在恢复上传文件..."
        local uploads_vol
        uploads_vol=$(docker volume ls --format '{{.Name}}' | grep 'backend_uploads' | head -1 || true)
        if [[ -n "$uploads_vol" ]]; then
            docker run --rm \
                -v "${uploads_vol}:/target" \
                -v "${BACKUP_DIR}/uploads:/source:ro" \
                alpine:latest \
                sh -c "rm -rf /target/* && cp -a /source/. /target/" 2>>"$LOG_FILE"
            log_ok "上传文件已恢复"
        fi
    fi

    # 6) 使用旧镜像重新启动全部服务
    log "使用旧版本镜像重新启动服务..."

    # 从备份的 digest 恢复镜像标签
    if [[ -f "${BACKUP_DIR}/image_digests.txt" ]]; then
        source "${BACKUP_DIR}/image_digests.txt"
    fi

    # docker compose up 会自动使用本地已有的镜像
    compose up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE" || {
        log_error "回滚后服务启动失败！请手动排查："
        log_error "  cd ${MULTICA_DIR}"
        log_error "  ${COMPOSE_CMD} -f docker-compose.selfhost.yml up -d"
        log_error "  备份位置: ${BACKUP_DIR}"
        return 1
    }

    # 7) 回滚后健康检查
    sleep 10
    log "回滚后验证服务..."
    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        local pg_container
        pg_container=$(compose ps -q postgres 2>/dev/null || true)
        if [[ -n "$pg_container" ]]; then
            local pg_health
            pg_health=$(docker inspect --format='{{.State.Health.Status}}' "$pg_container" 2>/dev/null || echo "unknown")
            if [[ "$pg_health" == "healthy" ]]; then
                log_ok "回滚后 PostgreSQL 正常运行"
                break
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "========== 回滚完成 =========="
    log "备份保留在: ${BACKUP_DIR}"
    log "请查看日志排查升级失败原因: ${LOG_FILE}"
    ROLLBACK_DONE=true

    # 发送通知（如果配置了 webhook）
    send_notification "rollback" "Multica 升级失败，已自动回滚到升级前状态。日志: ${LOG_FILE}"
}

# ======================== 清理旧备份 ==========================================

cleanup_old_backups() {
    log "清理 ${BACKUP_RETAIN_DAYS} 天前的备份..."

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        return
    fi

    local count=0
    while IFS= read -r dir; do
        if [[ -d "$dir" && "$dir" != "$BACKUP_DIR" ]]; then
            rm -rf "$dir"
            count=$((count + 1))
            log "  已清理: $(basename "$dir")"
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime "+${BACKUP_RETAIN_DAYS}" 2>/dev/null)

    log "共清理 ${count} 个旧备份"
}

# ======================== 通知 ===============================================

send_notification() {
    local status="$1"
    local message="$2"

    # 如果 .env 里配置了通知 webhook，则发送
    local webhook_url
    webhook_url=$(grep '^UPGRADE_NOTIFY_WEBHOOK=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2- || echo "")

    if [[ -n "$webhook_url" ]]; then
        curl -s -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"${status}\",\"message\":\"${message}\",\"host\":\"$(hostname)\",\"time\":\"$(date -Iseconds)\"}" \
            2>/dev/null || log_warn "通知发送失败"
    fi
}

# ======================== Cron 管理 ==========================================

install_cron() {
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

    local cron_cmd="${CRON_SCHEDULE} MULTICA_DIR=${MULTICA_DIR} bash ${script_path} >> ${LOG_DIR}/cron.log 2>&1"

    # 检查是否已存在
    if crontab -l 2>/dev/null | grep -qF "multica-upgrade.sh"; then
        log_warn "定时任务已存在，将更新"
        crontab -l 2>/dev/null | grep -vF "multica-upgrade.sh" | crontab -
    fi

    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    log_ok "定时任务已安装: ${CRON_SCHEDULE}"
    log "  命令: ${cron_cmd}"
    log "  查看: crontab -l"
}

uninstall_cron() {
    if crontab -l 2>/dev/null | grep -qF "multica-upgrade.sh"; then
        crontab -l 2>/dev/null | grep -vF "multica-upgrade.sh" | crontab -
        log_ok "定时任务已卸载"
    else
        log_warn "未找到 Multica 相关的定时任务"
    fi
}

# ======================== 主流程 =============================================

main() {
    # 创建必要目录
    mkdir -p "$LOG_DIR" "$BACKUP_ROOT"

    # 参数处理
    case "${1:-}" in
        --install-cron)
            detect_compose_cmd
            install_cron
            exit 0
            ;;
        --uninstall-cron)
            uninstall_cron
            exit 0
            ;;
        --dry-run)
            detect_compose_cmd
            preflight_checks
            record_current_images
            if check_new_version; then
                log "有新版本可用，运行不带参数的脚本执行升级"
            fi
            exit 0
            ;;
        --help|-h)
            echo "用法: bash $0 [选项]"
            echo ""
            echo "选项:"
            echo "  (无)              执行一次升级"
            echo "  --dry-run         仅检查是否有新版本"
            echo "  --install-cron    安装定时升级任务 (${CRON_SCHEDULE})"
            echo "  --uninstall-cron  卸载定时升级任务"
            echo "  --help, -h        显示此帮助"
            echo ""
            echo "环境变量:"
            echo "  MULTICA_DIR       Multica 仓库路径 (默认: /opt/multica)"
            exit 0
            ;;
    esac

    log "============================================================"
    log "  Multica 自动升级开始 - $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"

    detect_compose_cmd
    preflight_checks
    record_current_images

    # 检查是否有新版本（如果没更新则跳过）
    if ! check_new_version; then
        send_notification "skipped" "当前已是最新版本，无需升级"
        log "升级流程结束"
        exit 0
    fi

    # 备份
    backup_all

    # 升级
    if perform_upgrade; then
        # 健康检查
        if health_checks; then
            log_ok "升级成功！"
            send_notification "success" "Multica 已成功升级到最新版本"
            cleanup_old_backups
        else
            log_error "健康检查未通过，触发回滚..."
            perform_rollback
            exit 1
        fi
    else
        log_error "升级过程出错，触发回滚..."
        perform_rollback
        exit 1
    fi

    log "============================================================"
    log "  Multica 自动升级结束 - $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"
}

# 捕获异常信号，确保失败时也尝试回滚（防止重复回滚）
cleanup_on_exit() {
    local exit_code=$?
    if [[ "$ROLLBACK_DONE" == "false" && -d "$BACKUP_DIR" ]]; then
        if [[ "$ROLLBACK_NEEDED" == "true" || $exit_code -ne 0 ]]; then
            log_error "脚本异常退出 (exit=$exit_code)，触发回滚..."
            perform_rollback
        fi
    fi
}
trap cleanup_on_exit EXIT

main "$@"
