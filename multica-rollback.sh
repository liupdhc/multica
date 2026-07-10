#!/usr/bin/env bash
# ============================================================================
#  Multica 升级失败回滚脚本（独立版）
#  适用于 git clone + make selfhost 的 Docker Compose 部署
#
#  可独立使用，不依赖 multica-upgrade.sh
# ============================================================================
#
#  用法:
#    bash multica-rollback.sh                   # 自动回滚到最近一次备份
#    bash multica-rollback.sh --list            # 列出所有可用备份
#    bash multica-rollback.sh --from <备份目录名> # 指定某次备份进行回滚
#    bash multica-rollback.sh --db-only         # 仅恢复数据库（不动应用服务）
#    bash multica-rollback.sh --uploads-only    # 仅恢复上传文件卷
#    bash multica-rollback.sh --dry-run         # 预览将要执行的操作，不实际执行
#
set -euo pipefail

# ======================== 可配置变量 =========================================

MULTICA_DIR="${MULTICA_DIR:-/opt/multica}"
COMPOSE_FILE="${MULTICA_DIR}/docker-compose.selfhost.yml"
BACKUP_ROOT="${MULTICA_DIR}/backups"
LOG_DIR="${MULTICA_DIR}/logs"
HEALTH_CHECK_TIMEOUT=90
HEALTH_CHECK_INTERVAL=5

# ======================== 内部变量 ===========================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/rollback_${TIMESTAMP}.log"
SELECTED_BACKUP=""
MODE="full"          # full | db-only | uploads-only
DRY_RUN=false
COMPOSE_CMD=""

# ======================== 工具函数 ===========================================

log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_ok()  { log "OK:    $*"; }
log_warn(){ log "WARN:  $*"; }
log_error(){ log "ERROR: $*"; }
die()     { log_error "$*"; exit 1; }

detect_compose_cmd() {
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        die "未检测到 docker compose，请先安装"
    fi
}

compose() { ${COMPOSE_CMD} -f "$COMPOSE_FILE" "$@"; }

# 从 .env 读取 PG 连接参数
read_pg_env() {
    PG_USER=$(grep '^POSTGRES_USER=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || true)
    PG_DB=$(grep '^POSTGRES_DB=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || true)
    [[ -z "$PG_USER" ]] && PG_USER="multica"
    [[ -z "$PG_DB" ]] && PG_DB="multica"
}

# ======================== 列出可用备份 ========================================

list_backups() {
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        die "备份目录不存在: ${BACKUP_ROOT}（尚未执行过升级备份）"
    fi

    local backups=()
    while IFS= read -r dir; do
        [[ -d "$dir" ]] && backups+=("$dir")
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if [[ ${#backups[@]} -eq 0 ]]; then
        die "没有找到任何备份"
    fi

    echo ""
    echo "可用的备份（按时间倒序）:"
    echo "─────────────────────────────────────────────────────────────────"
    printf "  %-4s  %-20s  %-12s  %-12s  %-8s\n" "#" "备份时间" "数据库" "上传文件" "镜像信息"
    echo "─────────────────────────────────────────────────────────────────"

    local idx=1
    for dir in "${backups[@]}"; do
        local name
        name=$(basename "$dir")
        # 将 20260710_153022 格式化为可读时间
        local pretty_time
        pretty_time=$(echo "$name" | sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')

        local db_flag="✗" upload_flag="✗" img_flag="✗"
        [[ -f "${dir}/database.dump" ]] && {
            local db_size
            db_size=$(du -sh "${dir}/database.dump" 2>/dev/null | awk '{print $1}')
            db_flag="✓ ${db_size}"
        }
        [[ -d "${dir}/uploads" ]] && {
            local upload_count
            upload_count=$(find "${dir}/uploads" -type f 2>/dev/null | wc -l | tr -d ' ')
            upload_flag="✓ ${upload_count}文件"
        }
        [[ -f "${dir}/image_digests.txt" ]] && img_flag="✓"

        printf "  %-4s  %-20s  %-12s  %-12s  %-8s\n" "[$idx]" "$pretty_time" "$db_flag" "$upload_flag" "$img_flag"
        idx=$((idx + 1))
    done

    echo "─────────────────────────────────────────────────────────────────"
    echo "  备份目录: ${BACKUP_ROOT}"
    echo ""
}

# ======================== 选择备份 ============================================

select_backup() {
    local backups=()
    while IFS= read -r dir; do
        [[ -d "$dir" ]] && backups+=("$dir")
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if [[ ${#backups[@]} -eq 0 ]]; then
        die "没有找到任何备份"
    fi

    if [[ -n "$SELECTED_BACKUP" ]]; then
        # 用户通过 --from 指定了备份名
        local target="${BACKUP_ROOT}/${SELECTED_BACKUP}"
        [[ -d "$target" ]] || die "指定的备份不存在: ${target}"
        echo "$target"
        return
    fi

    # 默认选最新的一次
    echo "${backups[0]}"
}

# ======================== 预检 ===============================================

preflight() {
    [[ -d "$MULTICA_DIR" ]] || die "Multica 目录不存在: ${MULTICA_DIR}"
    [[ -f "$COMPOSE_FILE" ]] || die "Docker Compose 文件不存在: ${COMPOSE_FILE}"
    [[ -f "${MULTICA_DIR}/.env" ]] || die ".env 文件不存在"
    docker info &>/dev/null || die "Docker daemon 未运行"

    log_ok "预检通过"
}

# ======================== 确认操作 ============================================

confirm_action() {
    local backup_dir="$1"
    local backup_name
    backup_name=$(basename "$backup_dir")

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    Multica 回滚确认                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  备份来源:  ${backup_name}"
    echo "║  回滚模式:  ${MODE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "║  执行模式:  预览（dry-run，不会实际执行）"
    fi
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  将执行以下操作:"

    case "$MODE" in
        full)
            echo "║    1. 停止所有 Multica 容器"
            [[ -f "${backup_dir}/.env.bak" ]] && \
                echo "║    2. 恢复 .env 配置文件"
            [[ -f "${backup_dir}/docker-compose.selfhost.yml.bak" ]] && \
                echo "║    3. 恢复 docker-compose 文件"
            [[ -f "${backup_dir}/database.dump" ]] && \
                echo "║    4. 恢复 PostgreSQL 数据库"
            [[ -d "${backup_dir}/uploads" ]] && \
                echo "║    5. 恢复上传文件卷"
            echo "║    6. 使用旧版本镜像重启所有服务"
            echo "║    7. 健康检查验证"
            ;;
        db-only)
            echo "║    1. 停止 Backend 服务（保持数据库运行）"
            echo "║    2. 恢复 PostgreSQL 数据库"
            echo "║    3. 重启 Backend + Frontend"
            ;;
        uploads-only)
            echo "║    1. 恢复上传文件卷"
            echo "║    2. 重启 Backend（重新加载上传文件）"
            ;;
    esac

    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  ⚠  回滚会覆盖当前数据库和配置！"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] 预览完成，未执行任何操作"
        exit 0
    fi

    read -r -p "确认执行回滚？(输入 yes 继续): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "用户取消回滚"
        exit 0
    fi
}

# ======================== 恢复配置文件 =========================================

restore_configs() {
    local backup_dir="$1"

    log "── 恢复配置文件 ──"

    # .env
    if [[ -f "${backup_dir}/.env.bak" ]]; then
        # 先备份当前 .env 以防万一
        cp "${MULTICA_DIR}/.env" "${MULTICA_DIR}/.env.pre-rollback" 2>/dev/null || true
        cp "${backup_dir}/.env.bak" "${MULTICA_DIR}/.env"
        log_ok ".env 已恢复（升级前的 .env 保留为 .env.pre-rollback）"
    else
        log_warn "备份中无 .env.bak，跳过"
    fi

    # docker-compose 文件
    if [[ -f "${backup_dir}/docker-compose.selfhost.yml.bak" ]]; then
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.pre-rollback" 2>/dev/null || true
        cp "${backup_dir}/docker-compose.selfhost.yml.bak" "$COMPOSE_FILE"
        log_ok "docker-compose 文件已恢复"
    else
        log_warn "备份中无 docker-compose 文件备份，跳过"
    fi
}

# ======================== 恢复数据库 ==========================================

restore_database() {
    local backup_dir="$1"

    if [[ ! -f "${backup_dir}/database.dump" ]]; then
        log_warn "备份中无 database.dump，跳过数据库恢复"
        return 1
    fi

    log "── 恢复 PostgreSQL 数据库 ──"
    read_pg_env

    local pg_container
    pg_container=$(compose ps -q postgres 2>/dev/null || true)

    # 如果 postgres 没在运行，先启动它
    if [[ -z "$pg_container" ]]; then
        log "PostgreSQL 未运行，正在启动..."
        compose up -d postgres 2>&1 | tee -a "$LOG_FILE"
        sleep 10
        pg_container=$(compose ps -q postgres 2>/dev/null || true)
        [[ -z "$pg_container" ]] && die "PostgreSQL 启动失败，无法恢复数据库"
    fi

    # 等待 PG 健康
    log "等待 PostgreSQL 就绪..."
    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$pg_container" 2>/dev/null || echo "unknown")
        [[ "$health" == "healthy" ]] && break
        sleep 3
        elapsed=$((elapsed + 3))
    done

    # 断开所有活跃连接
    log "断开数据库活跃连接..."
    docker exec "$pg_container" psql -U "$PG_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${PG_DB}' AND pid <> pg_backend_pid();" \
        2>>"$LOG_FILE" || true

    # Drop + Recreate
    log "重建数据库 ${PG_DB}..."
    docker exec "$pg_container" psql -U "$PG_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS \"${PG_DB}\";" 2>>"$LOG_FILE"
    docker exec "$pg_container" psql -U "$PG_USER" -d postgres \
        -c "CREATE DATABASE \"${PG_DB}\" OWNER \"${PG_USER}\";" 2>>"$LOG_FILE"

    # pg_restore
    log "正在恢复数据（这可能需要几分钟）..."
    local restore_log
    restore_log=$(mktemp)
    docker exec -i "$pg_container" pg_restore \
        -U "$PG_USER" \
        -d "$PG_DB" \
        --no-owner \
        --no-privileges \
        --jobs=2 \
        < "${backup_dir}/database.dump" > "$restore_log" 2>&1 || true

    # 检查恢复结果
    local errors
    errors=$(grep -c "ERROR" "$restore_log" 2>/dev/null || echo "0")
    if [[ "$errors" -gt 0 && "$errors" -lt 5 ]]; then
        log_warn "pg_restore 有 ${errors} 个非致命警告（通常不影响使用）"
        grep "ERROR" "$restore_log" | head -5 >> "$LOG_FILE"
    elif [[ "$errors" -ge 5 ]]; then
        log_error "pg_restore 报告了 ${errors} 个错误，请检查日志"
        grep "ERROR" "$restore_log" >> "$LOG_FILE"
    else
        log_ok "数据库恢复完成"
    fi
    rm -f "$restore_log"

    # 验证表数量
    local table_count
    table_count=$(docker exec "$pg_container" psql -U "$PG_USER" -d "$PG_DB" -t \
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ' || echo "?")
    log "  当前 public schema 表数量: ${table_count}"
}

# ======================== 恢复上传文件 ========================================

restore_uploads() {
    local backup_dir="$1"

    if [[ ! -d "${backup_dir}/uploads" || -z "$(ls -A "${backup_dir}/uploads" 2>/dev/null)" ]]; then
        log_warn "备份中无上传文件或目录为空，跳过"
        return 1
    fi

    log "── 恢复上传文件卷 ──"

    local uploads_vol
    uploads_vol=$(docker volume ls --format '{{.Name}}' | grep 'backend_uploads' | head -1 || true)

    if [[ -z "$uploads_vol" ]]; then
        log_warn "未找到 backend_uploads 卷（服务未启动过？），跳过"
        return 1
    fi

    local file_count
    file_count=$(find "${backup_dir}/uploads" -type f 2>/dev/null | wc -l | tr -d ' ')
    log "正在恢复 ${file_count} 个上传文件..."

    docker run --rm \
        -v "${uploads_vol}:/target" \
        -v "${backup_dir}/uploads:/source:ro" \
        alpine:latest \
        sh -c 'rm -rf /target/* 2>/dev/null; cp -a /source/. /target/' 2>>"$LOG_FILE"

    log_ok "上传文件已恢复 (${file_count} 个文件)"
}

# ======================== 重启服务 ============================================

restart_services() {
    log "── 重启所有服务 ──"

    # 完全停掉再启动
    compose down 2>&1 | tee -a "$LOG_FILE" || true
    sleep 3

    compose up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE" || {
        die "服务启动失败，请手动排查: cd ${MULTICA_DIR} && ${COMPOSE_CMD} -f docker-compose.selfhost.yml up -d"
    }

    log "服务已启动，等待健康检查..."
}

# ======================== 健康检查 ============================================

verify_health() {
    log "── 回滚后健康检查 (超时: ${HEALTH_CHECK_TIMEOUT}s) ──"

    local elapsed=0
    local pg_ok=false be_ok=false fe_ok=false

    while [[ $elapsed -lt $HEALTH_CHECK_TIMEOUT ]]; do
        # PostgreSQL
        if [[ "$pg_ok" == "false" ]]; then
            local pg_c
            pg_c=$(compose ps -q postgres 2>/dev/null || true)
            if [[ -n "$pg_c" ]]; then
                local h
                h=$(docker inspect --format='{{.State.Health.Status}}' "$pg_c" 2>/dev/null || echo "unknown")
                [[ "$h" == "healthy" ]] && { pg_ok=true; log_ok "PostgreSQL ✓ (${elapsed}s)"; }
            fi
        fi

        # Backend
        if [[ "$pg_ok" == "true" && "$be_ok" == "false" ]]; then
            local be_port
            be_port=$(grep '^BACKEND_PORT=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "8080")
            [[ -z "$be_port" ]] && be_port="8080"
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${be_port}/api/health" 2>/dev/null || echo "000")
            [[ "$code" == "000" ]] && code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${be_port}/health" 2>/dev/null || echo "000")
            if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
                be_ok=true
                log_ok "Backend ✓ HTTP ${code} (${elapsed}s)"
            fi
        fi

        # Frontend
        if [[ "$be_ok" == "true" && "$fe_ok" == "false" ]]; then
            local fe_port
            fe_port=$(grep '^FRONTEND_PORT=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "3000")
            [[ -z "$fe_port" ]] && fe_port="3000"
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${fe_port}" 2>/dev/null || echo "000")
            if [[ "$code" =~ ^(200|301|302|307)$ ]]; then
                fe_ok=true
                log_ok "Frontend ✓ HTTP ${code} (${elapsed}s)"
            fi
        fi

        [[ "$pg_ok" == "true" && "$be_ok" == "true" && "$fe_ok" == "true" ]] && {
            log "========== 健康检查全部通过 =========="
            return 0
        }

        sleep "$HEALTH_CHECK_INTERVAL"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
    done

    log_error "健康检查超时，部分服务可能未就绪:"
    log_error "  PostgreSQL: ${pg_ok}  |  Backend: ${be_ok}  |  Frontend: ${fe_ok}"
    log_error "请手动检查: ${COMPOSE_CMD} -f ${COMPOSE_FILE} logs"
    return 1
}

# ======================== 回滚后的安全网 ======================================

post_rollback_safety_net() {
    local backup_dir="$1"

    # 创建一个"回滚保护快照"，防止回滚后再次丢失
    local safety_dir="${BACKUP_ROOT}/_rollback-safety-${TIMESTAMP}"
    mkdir -p "$safety_dir"
    cp "${MULTICA_DIR}/.env" "${safety_dir}/.env.bak" 2>/dev/null || true
    cp "$COMPOSE_FILE" "${safety_dir}/docker-compose.selfhost.yml.bak" 2>/dev/null || true

    log "回滚保护快照已保存: ${safety_dir}"
    log "  如需再次恢复，使用: bash $0 --from $(basename "$safety_dir")"
}

# ======================== 主流程 =============================================

main() {
    mkdir -p "$LOG_DIR" "$BACKUP_ROOT"

    # 参数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list|-l)
                detect_compose_cmd
                list_backups
                exit 0
                ;;
            --from)
                [[ -z "${2:-}" ]] && die "--from 需要指定备份目录名"
                SELECTED_BACKUP="$2"
                shift
                ;;
            --db-only)
                MODE="db-only"
                ;;
            --uploads-only)
                MODE="uploads-only"
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --help|-h)
                echo "用法: bash $0 [选项]"
                echo ""
                echo "选项:"
                echo "  (无)                    自动回滚到最近一次备份"
                echo "  --list, -l              列出所有可用备份"
                echo "  --from <备份目录名>      指定备份进行回滚"
                echo "  --db-only               仅恢复数据库"
                echo "  --uploads-only          仅恢复上传文件卷"
                echo "  --dry-run               预览操作，不实际执行"
                echo "  --help, -h              显示此帮助"
                echo ""
                echo "环境变量:"
                echo "  MULTICA_DIR             Multica 仓库路径 (默认: /opt/multica)"
                exit 0
                ;;
            *)
                die "未知参数: $1（使用 --help 查看帮助）"
                ;;
        esac
        shift
    done

    log "============================================================"
    log "  Multica 回滚开始 - $(date '+%Y-%m-%d %H:%M:%S')"
    log "============================================================"

    detect_compose_cmd
    preflight

    # 选择备份
    local backup_dir
    backup_dir=$(select_backup)
    log "使用备份: $(basename "$backup_dir")"

    # 确认
    confirm_action "$backup_dir"

    # 执行回滚
    case "$MODE" in
        full)
            compose stop frontend backend 2>&1 | tee -a "$LOG_FILE" || true
            sleep 2
            restore_configs "$backup_dir"
            restore_database "$backup_dir" || true
            restore_uploads "$backup_dir" || true
            restart_services
            verify_health || true
            post_rollback_safety_net "$backup_dir"
            ;;
        db-only)
            log "模式: 仅恢复数据库"
            compose stop backend 2>&1 | tee -a "$LOG_FILE" || true
            sleep 2
            restore_database "$backup_dir"
            compose up -d backend frontend 2>&1 | tee -a "$LOG_FILE"
            verify_health || true
            ;;
        uploads-only)
            log "模式: 仅恢复上传文件"
            restore_uploads "$backup_dir"
            compose restart backend 2>&1 | tee -a "$LOG_FILE" || true
            verify_health || true
            ;;
    esac

    log "============================================================"
    log "  回滚完成 - $(date '+%Y-%m-%d %H:%M:%S')"
    log "  详细日志: ${LOG_FILE}"
    log "============================================================"

    # 输出后续操作提示
    echo ""
    echo "后续操作:"
    echo "  查看服务状态:  cd ${MULTICA_DIR} && ${COMPOSE_CMD} -f docker-compose.selfhost.yml ps"
    echo "  查看后端日志:  cd ${MULTICA_DIR} && ${COMPOSE_CMD} -f docker-compose.selfhost.yml logs -f backend"
    echo "  访问前端:      http://127.0.0.1:$(grep '^FRONTEND_PORT=' "${MULTICA_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo 3000)"
    echo ""
}

main "$@"
