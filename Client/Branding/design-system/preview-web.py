#!/usr/bin/env python3
"""Offline preview of the real embedded pages. No database, credentials, or writes.

Run from any directory, then open http://127.0.0.1:18761 (Passkey) or :18762
(admin). Add ?appearance=dark to inspect the dark tokens independently of the OS.
Passkey result layouts: ?state=signed-in, /register?state=receipt,
/device?request=DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD&state=approved.
"""
import argparse
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
from pathlib import Path
import threading
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
DATE = '2026-10-21T08:00:00Z'
MEMBERS = [
    dict(id='member_oliver', display_name='Oliver', enabled=True, created_at=DATE, login_active=True, last_login_at=DATE, credential_expires_at=1792598400, participant_identity='member_oliver.login_preview.room_preview'),
    dict(id='member_juniper', display_name='Juniper', enabled=True, created_at=DATE, login_active=False),
    dict(id='member_long', display_name='一个比较长的朋友昵称', enabled=True, created_at=DATE, login_active=True, last_login_at=DATE, credential_expires_at=1792598400, participant_identity='member_long.login_preview.room_preview'),
    dict(id='member_alex', display_name='Alex', enabled=False, created_at=DATE, login_active=False),
]
PARTICIPANTS = [dict(id=m['participant_identity'], display_name=m['display_name']) for m in MEMBERS if m['login_active']]
ROOMS = [dict(room_id=identifier, display_name=name, is_default=i == 0, password_required=locked, participants=PARTICIPANTS if i == 0 else [], media_status='available')
         for i, (identifier, name, locked) in enumerate([
             ('friends', '朋友客厅', False), ('focus', '一起专注', True), ('games', '游戏小队', False), ('music', '音乐角落', False), ('quiet', '安静待一会儿', True)])]
OVERVIEW = dict(members=MEMBERS, rooms=ROOMS, participants=PARTICIPANTS, max_members=0, media_status='available', sqlite_version='3.54.1 · 示例', livekit_url='wss://chirp.youzifeile.cn', media_transport='udp', e2ee_required=True, registration_closed=False, registrations=[
    dict(request_id='CHIRP-PREVIEW-OLIVER-001', nickname='Morgan', created_at=DATE),
    dict(request_id='CHIRP-PREVIEW-JUNIPER-002', nickname='Juniper', created_at=DATE, approved_at=DATE, member_id='member_juniper'),
])


class Preview(BaseHTTPRequestHandler):
    def __init__(self, *args, surface, **kwargs):
        self.surface = surface
        super().__init__(*args, **kwargs)

    def respond(self, data, content_type, status=200):
        if isinstance(data, str):
            data = data.encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Security-Policy', CSP)
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        appearance = query.get('appearance', ['system'])[0]
        if url.path == '/admin/api/overview' and self.surface == 'admin':
            return self.respond(json.dumps(OVERVIEW), 'application/json')
        if url.path == '/admin/api/client-versions' and self.surface == 'admin':
            return self.respond(json.dumps({'platforms': [dict(platform=p, latest_version='0.14.0', latest_build=14, minimum_version='0.14.0', minimum_build=14) for p in ('ios', 'macos', 'windows', 'android')]}), 'application/json')
        if url.path == '/api/session' and self.surface == 'passkey':
            return self.respond('{"member":null}', 'application/json')
        if url.path == '/assets/preview.css':
            return self.respond('.preview-label{position:fixed;z-index:9999;bottom:8px;left:8px;padding:5px 10px;border:1px solid #626d61;border-radius:8px;background:#252c25;color:#fff;font:11px/1.5 system-ui;pointer-events:none}', 'text/css')
        if url.path.startswith('/assets/') or (self.surface == 'admin' and url.path.startswith('/admin/assets/')):
            name = url.path.removeprefix('/admin/assets/').removeprefix('/assets/')
            if name not in ('theme.css', 'icon.svg', 'styles.css', 'app.js', 'i18n.js', 'native-login.js', 'client-version.js', 'locales/zh-CN.js', 'locales/en.js'):
                return self.respond('Not found', 'text/plain', 404)
            folder = ROOT / 'internal' / ('webui' if name in ('theme.css', 'icon.svg', 'i18n.js', 'client-version.js', 'locales/zh-CN.js', 'locales/en.js') else self.surface + 'http/web')
            data = (folder / name).read_text(encoding='utf-8')
            if appearance in ('light', 'dark'):
                # Preview only: exercise the exact production media rule without
                # changing the user's OS or browser appearance preference.
                data = data.replace('@media (prefers-color-scheme: dark)', '@media all' if appearance == 'dark' else '@media not all')
                data = data.replace('@media(prefers-color-scheme:dark)', '@media all' if appearance == 'dark' else '@media not all')
                if name == 'theme.css':
                    data += f'\n:root {{ color-scheme: {appearance}; }}\n'
            kind = 'text/javascript' if name.endswith('.js') else mimetypes.guess_type(name)[0]
            return self.respond(data, kind)
        pages = {'/': 'index.html'}
        if self.surface == 'admin':
            pages['/admin/'] = 'index.html'
        if self.surface == 'passkey':
            pages.update({'/register': 'register.html', '/device': 'device.html'})
        if url.path not in pages:
            return self.respond('Not found', 'text/plain', 404)
        html = (ROOT / 'internal' / (self.surface + 'http') / 'web' / pages[url.path]).read_text(encoding='utf-8')
        html = html.replace('</head>', '<link rel="stylesheet" href="/assets/preview.css"></head>')
        html = html.replace('<body>', '<body><aside class="preview-label">离线设计预览 · 示例数据 · 写入禁用</aside>')
        if '<aside class="preview-label">' not in html:
            position = html.index('>', html.index('<body')) + 1
            html = html[:position] + '<aside class="preview-label">离线设计预览 · 示例数据 · 写入禁用</aside>' + html[position:]
        if appearance in ('light', 'dark'):
            html = html.replace('/assets/theme.css', f'/assets/theme.css?appearance={appearance}').replace('/assets/icon.svg', f'/assets/icon.svg?appearance={appearance}')
        state = query.get('state', [''])[0]
        if state == 'signed-in' and self.surface == 'passkey' and url.path == '/':
            html = html.replace('<div id="login-panel">', '<div id="login-panel" hidden>').replace('id="signed-in-panel" role="status" tabindex="-1" hidden', 'id="signed-in-panel" role="status" tabindex="-1"').replace('id="signed-in-name" data-i18n-slot="name"></strong>', 'id="signed-in-name" data-i18n-slot="name">Oliver（示例）</strong>')
        if state == 'receipt' and self.surface == 'passkey' and url.path == '/register':
            html = html.replace('<div id="registration-panel">', '<div id="registration-panel" hidden>').replace('id="receipt-panel" hidden', 'id="receipt-panel"').replace('id="receipt-value" readonly', 'id="receipt-value" value="CHIRP-PREVIEW-001" readonly')
        if state == 'approved' and self.surface == 'passkey' and url.path == '/device':
            html = html.replace('<div id="device-panel">', '<div id="device-panel" hidden>').replace('id="device-approved" role="status" tabindex="-1" hidden', 'id="device-approved" role="status" tabindex="-1"')
        return self.respond(html, 'text/html; charset=utf-8')

    def refuse_write(self):
        return self.respond('{"error":{"message":"离线设计预览不执行任何写入或身份验证。"}}', 'application/json', 405)

    do_POST = do_PUT = do_DELETE = do_PATCH = refuse_write


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--passkey-port', type=int, default=18761)
    parser.add_argument('--admin-port', type=int, default=18762)
    args = parser.parse_args()
    passkey = ThreadingHTTPServer(('127.0.0.1', args.passkey_port), partial(Preview, surface='passkey'))
    admin = ThreadingHTTPServer(('127.0.0.1', args.admin_port), partial(Preview, surface='admin'))
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    print(f'Passkey: http://127.0.0.1:{args.passkey_port}\nAdmin: http://127.0.0.1:{args.admin_port}', flush=True)
    try:
        passkey.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        admin.shutdown()
        admin.server_close()
        passkey.server_close()
