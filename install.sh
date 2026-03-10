#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

info() { printf '[%s] [INFO] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$SCRIPT_NAME" "$*" >&2; }
error() { printf '[%s] [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }

trap 'error "Failed at line $LINENO."' ERR

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 1
  fi
}

compose_cmd=("docker" "compose")
if ! docker compose version >/dev/null 2>&1; then
  if require_cmd docker-compose; then
    compose_cmd=("docker-compose")
  else
    error "Docker Compose is not installed."
    echo "Install Docker Compose plugin: https://docs.docker.com/compose/install/" >&2
    exit 1
  fi
fi

if ! require_cmd docker; then
  error "Docker is not installed."
  echo "Install Docker: https://docs.docker.com/engine/install/" >&2
  exit 1
fi

if ! require_cmd git; then
  error "Git is not installed."
  echo "Install Git: https://git-scm.com/downloads" >&2
  exit 1
fi

if ! require_cmd curl; then
  warn "curl is not installed. Health check fallback may fail."
fi

if ! docker info >/dev/null 2>&1; then
  error "Docker daemon is not reachable for current user."
  echo "Ensure Docker service is running and your user can access /var/run/docker.sock." >&2
  exit 1
fi

is_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$ ]]
}

is_valid_url() {
  local u="$1"
  [[ "$u" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]]
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

prompt_input() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local value

  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "$prompt_text [$default_value]: " value
      value="${value:-$default_value}"
    else
      read -r -p "$prompt_text: " value
    fi

    case "$var_name" in
      DOMAIN)
        if is_valid_domain "$value"; then break; fi
        warn "Invalid domain format."
        ;;
      PUBLIC_URL)
        if is_valid_url "$value"; then break; fi
        warn "Invalid URL format. Use http(s)://..."
        ;;
      WEB_PORT|API_PORT)
        if is_valid_port "$value"; then break; fi
        warn "Invalid port. Must be 1-65535."
        ;;
      POSTGRES_PASSWORD|REDIS_PASSWORD|GITHUB_WEBHOOK_SECRET)
        if [[ -n "$value" ]]; then break; fi
        warn "Value cannot be empty."
        ;;
      *)
        if [[ -n "$value" ]]; then break; fi
        warn "Value cannot be empty."
        ;;
    esac
  done

  printf '%s' "$value"
}

set_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qE "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*$|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
  rm -f "${file}.bak"
}

choose_nginx_container() {
  local containers
  containers="$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /nginx/ {print $1}')"
  if [[ -z "$containers" ]]; then
    return 1
  fi

  local count
  count="$(printf '%s\n' "$containers" | wc -l | tr -d ' ')"
  if [[ "$count" -eq 1 ]]; then
    printf '%s' "$containers"
    return 0
  fi

  info "Multiple nginx containers detected:"
  nl -w2 -s'. ' <<< "$containers"

  local choice selected
  while true; do
    read -r -p "Choose nginx container number for maro.run routing: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      selected="$(sed -n "${choice}p" <<< "$containers")"
      printf '%s' "$selected"
      return 0
    fi
    warn "Invalid selection."
  done
}

detect_nginx_config_dir() {
  local container="$1"
  local dir
  for dir in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
    if docker exec "$container" sh -lc "test -d '$dir'" >/dev/null 2>&1; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

write_updater_script() {
  local project_dir="$1"
  local branch="$2"
  local services="$3"

  mkdir -p "$project_dir/infra/updater"

  cat > "$project_dir/infra/updater/auto-update.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${project_dir}"
DEPLOY_BRANCH="${branch}"
DEPLOY_SERVICES="${services}"

cd "\$PROJECT_DIR"

git fetch origin "\$DEPLOY_BRANCH"
before_commit="\$(git rev-parse HEAD)"
git pull --ff-only origin "\$DEPLOY_BRANCH"
after_commit="\$(git rev-parse HEAD)"

if [[ "\$before_commit" == "\$after_commit" ]]; then
  exit 0
fi

if docker compose version >/dev/null 2>&1; then
  compose_cmd=(docker compose)
else
  compose_cmd=(docker-compose)
fi

\"\${compose_cmd[@]}\" build \$DEPLOY_SERVICES
\"\${compose_cmd[@]}\" up -d \$DEPLOY_SERVICES
EOF

  chmod +x "$project_dir/infra/updater/auto-update.sh"
}

install_cron_updater() {
  local project_dir="$1"
  local marker="# maro-run-auto-updater"
  local cron_line="*/5 * * * * $project_dir/infra/updater/auto-update.sh $marker"

  if ! require_cmd crontab; then
    warn "crontab not found. Skipping auto-updater cron installation."
    return 1
  fi

  local current
  current="$(crontab -l 2>/dev/null | sed "/$marker/d")"
  printf '%s\n%s\n' "$current" "$cron_line" | crontab -
  return 0
}

main() {
  local repo_url_default="https://github.com/USERNAME/maro-run.git"
  local project_dir_default="/opt/maro-run"
  local branch_default="main"

  local repo_url project_dir deploy_branch
  repo_url="$(prompt_input REPO_URL "Repository URL" "$repo_url_default")"
  project_dir="$(prompt_input PROJECT_DIR "Project directory" "$project_dir_default")"
  deploy_branch="$(prompt_input DEPLOY_BRANCH "Deploy branch" "$branch_default")"

  mkdir -p "$(dirname "$project_dir")"

  if [[ -d "$project_dir/.git" ]]; then
    info "Repository exists. Updating latest code."
    git -C "$project_dir" fetch origin "$deploy_branch"
    git -C "$project_dir" checkout "$deploy_branch"
    git -C "$project_dir" pull --ff-only origin "$deploy_branch"
  else
    if [[ -d "$project_dir" ]] && [[ -n "$(ls -A "$project_dir" 2>/dev/null)" ]]; then
      error "Project directory exists and is not empty: $project_dir"
      exit 1
    fi
    info "Cloning repository into $project_dir"
    git clone "$repo_url" "$project_dir"
    git -C "$project_dir" checkout "$deploy_branch"
  fi

  local env_file="$project_dir/.env"
  if [[ ! -f "$env_file" ]]; then
    info "Creating .env file"
    if [[ -f "$project_dir/.env.example" ]]; then
      cp "$project_dir/.env.example" "$env_file"
    else
      : > "$env_file"
    fi
  fi

  local domain public_url web_port api_port pg_password redis_password webhook_secret
  domain="$(prompt_input DOMAIN "Domain name" "maro.run")"
  public_url="$(prompt_input PUBLIC_URL "Public URL" "https://$domain")"
  web_port="$(prompt_input WEB_PORT "Frontend internal port" "3000")"
  api_port="$(prompt_input API_PORT "API internal port" "4000")"
  pg_password="$(prompt_input POSTGRES_PASSWORD "Database password" "postgres")"
  redis_password="$(prompt_input REDIS_PASSWORD "Redis password" "redis")"
  webhook_secret="$(prompt_input GITHUB_WEBHOOK_SECRET "GitHub webhook secret" "")"

  set_env_var "$env_file" DOMAIN "$domain"
  set_env_var "$env_file" PUBLIC_URL "$public_url"
  set_env_var "$env_file" BASE_URL "$public_url"
  set_env_var "$env_file" WEB_PORT "$web_port"
  set_env_var "$env_file" API_PORT "$api_port"
  set_env_var "$env_file" PUBLIC_API_BASE_URL "/api"
  set_env_var "$env_file" POSTGRES_DB "maro_run"
  set_env_var "$env_file" POSTGRES_USER "postgres"
  set_env_var "$env_file" POSTGRES_PASSWORD "$pg_password"
  set_env_var "$env_file" REDIS_PASSWORD "$redis_password"
  set_env_var "$env_file" DATABASE_URL "postgresql://postgres:${pg_password}@postgres:5432/maro_run?schema=public"
  set_env_var "$env_file" REDIS_URL "redis://:${redis_password}@redis:6379"
  set_env_var "$env_file" LOG_LEVEL "info"
  set_env_var "$env_file" NGINX_PORT "80"
  set_env_var "$env_file" GITHUB_WEBHOOK_SECRET "$webhook_secret"
  set_env_var "$env_file" DEPLOY_BRANCH "$deploy_branch"
  set_env_var "$env_file" PROJECT_DIR "$project_dir"

  local nginx_container=""
  local nginx_config_dir=""
  local deploy_services="web api postgres redis updater"

  if nginx_container="$(choose_nginx_container)"; then
    info "Using existing nginx container: $nginx_container"
    if nginx_config_dir="$(detect_nginx_config_dir "$nginx_container")"; then
      info "Detected nginx config directory: $nginx_config_dir"
    else
      warn "Could not detect nginx config directory in container; skipping nginx integration."
      nginx_container=""
    fi
  else
    info "No existing nginx container detected. Internal nginx service will be deployed."
    deploy_services="$deploy_services nginx"
    if [[ "$web_port" != "3000" || "$api_port" != "4000" ]]; then
      warn "Internal nginx uses web:3000 and api:4000. Overriding WEB_PORT/API_PORT to 3000/4000."
      web_port="3000"
      api_port="4000"
      set_env_var "$env_file" WEB_PORT "$web_port"
      set_env_var "$env_file" API_PORT "$api_port"
    fi
  fi

  set_env_var "$env_file" DEPLOY_SERVICES "$deploy_services"

  cd "$project_dir"
  info "Pulling images"
  "${compose_cmd[@]}" pull || warn "docker compose pull returned non-zero. Continuing with build."

  info "Building containers"
  "${compose_cmd[@]}" build $deploy_services

  info "Starting containers"
  "${compose_cmd[@]}" up -d $deploy_services

  local updater_status="not-installed"

  if [[ -n "$nginx_container" ]]; then
    local nginx_network
    nginx_network="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$nginx_container" | head -n1 | tr -d '[:space:]')"

    if [[ -n "$nginx_network" ]]; then
      info "Connecting maro.run containers to nginx network: $nginx_network"
      local svc cid alias
      for svc in web api updater; do
        cid="$("${compose_cmd[@]}" ps -q "$svc" | head -n1)"
        if [[ -n "$cid" ]]; then
          alias="maro-$svc"
          docker network connect --alias "$alias" "$nginx_network" "$cid" >/dev/null 2>&1 || true
        fi
      done
    fi

    local temp_conf
    temp_conf="$(mktemp)"

    cat > "$temp_conf" <<EOF
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://maro-web:$web_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api {
        proxy_pass http://maro-api:$api_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location /go {
        proxy_pass http://maro-api:$api_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location = /webhook {
        proxy_pass http://maro-updater:8080/webhook;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }
}
EOF

    local conf_name="maro-run.conf"
    if docker exec "$nginx_container" sh -lc "test -f '$nginx_config_dir/$conf_name'" >/dev/null 2>&1; then
      conf_name="maro-run-$(date +%Y%m%d%H%M%S).conf"
    fi

    info "Copying nginx config as $conf_name"
    docker cp "$temp_conf" "$nginx_container:$nginx_config_dir/$conf_name"
    rm -f "$temp_conf"

    info "Testing nginx configuration"
    docker exec "$nginx_container" nginx -t

    info "Reloading nginx"
    docker exec "$nginx_container" nginx -s reload
  fi

  write_updater_script "$project_dir" "$deploy_branch" "$deploy_services"
  if install_cron_updater "$project_dir"; then
    updater_status="cron-installed (every 5 minutes)"
  else
    updater_status="cron-not-installed"
  fi

  info "Running health check"
  local ok="false"
  local attempt
  for attempt in $(seq 1 20); do
    if curl -fsS "http://localhost" >/dev/null 2>&1 || curl -fsS -H "Host: $domain" "http://localhost" >/dev/null 2>&1; then
      ok="true"
      break
    fi
    sleep 3
  done

  if [[ "$ok" != "true" ]]; then
    warn "Health check did not return success on http://localhost after retries."
  fi

  echo
  echo "Installation complete"
  echo "Website URL: $public_url"
  echo "Toolbox URL: $public_url/toolbox"
  echo "Updater status: $updater_status"
}

main "$@"
