#!/bin/sh
# Run the public HTTPS stack on isolated volumes, without binding host ports or contacting a CA.
set -eu
cd "$(dirname "$0")/.."
export CHIRP_IMAGE=${1:?supply the local public image}
export CHIRP_DOMAIN=chirp.test CHIRP_PUBLIC_ORIGIN=https://chirp.test CHIRP_RTC_NODE_IP=''
export CHIRP_ACME_EMAIL=release@example.test COMPOSE_PROFILES=https
export CHIRP_DNS_PLUGIN=cloudflare

work=$(mktemp -d "${TMPDIR:-/tmp}/chirp-compose-XXXXXXXX")
prefix=$(basename "$work" | tr '[:upper:]' '[:lower:]')
project=''
compose() {
    docker compose -p "$project" --env-file /dev/null -f compose.yaml -f "$work/check.yaml" "$@"
}
cleanup() {
    if [ -n "$project" ]; then compose down -v --remove-orphans || :; fi
    rm -rf "$work"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

cat > "$work/check.yaml" <<'YAML'
services:
  app:
    ports: !reset []
  livekit:
    ports: !reset []
  nginx:
    ports: !reset []
    volumes:
      - test-nginx:/config
    environment:
      CURL_CA_BUNDLE: /config/keys/letsencrypt/fullchain.pem
volumes:
  test-nginx:
networks:
  default:
    internal: true
YAML

for CHIRP_ACME_METHOD in http dns; do
    export CHIRP_ACME_METHOD
    project="$prefix-$CHIRP_ACME_METHOD"
    compose config --quiet
    # Certbot reuses this test-only certificate. Each mode starts with its own account and state.
    compose run --rm -T --no-deps --entrypoint sh nginx -ec '
        cert=/config/etc/letsencrypt/live/$URL
        mkdir -p "$cert"
        openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=$URL" \
            -addext "subjectAltName=DNS:$URL" -keyout "$cert/privkey.pem" -out "$cert/fullchain.pem" 2>/dev/null
    '
    if ! compose up -d --no-build --wait --wait-timeout 180; then
        compose logs --tail=80 nginx
        exit 1
    fi
    compose exec -T nginx sh -ec '
        nginx -t
        config=/config/etc/letsencrypt/cli.ini
        if [ "$VALIDATION" = dns ]; then auth=dns-$DNSPLUGIN; else auth=standalone; fi
        grep -Eq "^authenticator[[:space:]]*=[[:space:]]*$auth$" "$config"
        grep -Eq "^preferred-challenges[[:space:]]*=[[:space:]]*$VALIDATION$" "$config"
        if [ "$VALIDATION" = http ]; then
            hooks=/config/etc/letsencrypt/renewal-hooks
            test -x "$hooks/pre/20-wait-for-nginx"
            run-parts "$hooks/pre"
            test "$(s6-svstat -o up /run/service/svc-nginx)" = false
            run-parts "$hooks/post"
            curl --noproxy "*" -fsS --retry 5 --retry-connrefused --retry-delay 1 \
                --resolve "$URL:443:127.0.0.1" "https://$URL/healthz" >/dev/null
        fi
        status() { curl --noproxy "*" -sS -o /dev/null -w "%{http_code}" --resolve "$URL:443:127.0.0.1" "https://$URL$1"; }
        test "$(status /healthz)" = 200
        test "$(status /authorization/healthz)" = 204
        test "$(status /authorization/v5/snapshot)" = 405
        test "$(status /register)" = 200
        test "$(status /rtc/v1/validate)" = 401
        test "$(status /twirp/livekit.RoomService/ListRooms)" = 404
        test "$(status /internal/probe)" = 404
        test "$(curl --noproxy "*" -sS -o /dev/null -w "%{redirect_url}" http://127.0.0.1/register)" = "https://$URL/register"
    '
    compose down -v --remove-orphans
    project=''
done
