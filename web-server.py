import http.server
import json
import urllib.request
import urllib.error
import urllib.parse
import ssl
import os
import time
import subprocess
import base64
import re

PORT = 80
PVE_HOST = "__PVE_HOST__"
PVE_NODE = "__PVE_NODE__"
API_TOKEN = "__API_TOKEN__"

# --- NEW DIRECTORY ARCHITECTURE ---
APP_DIR = "/opt/dashboard/apps"
ICON_DIR = "/opt/dashboard/apps/icons" # NEW: Strict Icon Directory
CONFIG_FILE = "/opt/dashboard/config.json"
PULSE_FILE = "/run/dashboard_pulse.json"  

os.makedirs(APP_DIR, exist_ok=True)
os.makedirs(ICON_DIR, exist_ok=True) # Ensure the Icon Directory exists

if not os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE, 'w') as f:
        json.dump({"grid_order": [], "active_theme": "odysseus", "custom_themes": {}, "pending_urls": {}}, f)

def load_config():
    with open(CONFIG_FILE, 'r') as f: return json.load(f)

def save_config(data):
    with open(CONFIG_FILE, 'w') as f: json.dump(data, f, indent=4)

class HomeOSRequestHandler(http.server.SimpleHTTPRequestHandler):
    
    def do_GET(self):
        # ---------------------------------------------------------
        # HYBRID ROUTE: Intercept Icon Requests and serve from /apps/
        # ---------------------------------------------------------
        if self.path.startswith('/icons/'):
            try:
                icon_filename = os.path.basename(self.path)
                icon_path = os.path.join(ICON_DIR, icon_filename)
                
                if os.path.exists(icon_path):
                    with open(icon_path, 'rb') as f:
                        self.send_response(200)
                        if icon_filename.endswith('.png'): self.send_header('Content-Type', 'image/png')
                        elif icon_filename.endswith('.svg'): self.send_header('Content-Type', 'image/svg+xml')
                        elif icon_filename.endswith('.jpg') or icon_filename.endswith('.jpeg'): self.send_header('Content-Type', 'image/jpeg')
                        else: self.send_header('Content-Type', 'application/octet-stream')
                        self.end_headers()
                        self.wfile.write(f.read())
                else:
                    self.send_error(404, "Icon Not Found")
            except Exception as e:
                self.send_error(500, str(e))
                
        # ---------------------------------------------------------
        # THE COMPILER: Merges RAM hardware data with SSD Configs
        # ---------------------------------------------------------
        elif self.path.startswith('/api/dashboard_state.json'):
            try:
                config = load_config()
                pulse_data = {"system": {}, "applications": [], "stopped_apps": []}
                
                if os.path.exists(PULSE_FILE):
                    try:
                        with open(PULSE_FILE, 'r') as f: pulse_data = json.load(f)
                    except Exception: pass
                
                all_apps = pulse_data.get('applications', []) + pulse_data.get('stopped_apps', [])
                pending_urls = config.get("pending_urls", {})
                config_changed = False
                merged_applications = []
                
                for app in all_apps:
                    vmid = str(app.get('id'))
                    safe_name = app.get('name', '').lower().replace(' ', '')
                    safe_raw = app.get('raw_name', '').lower()
                    app_json_path = os.path.join(APP_DIR, f"{vmid}.json")
                    app_config = {}
                    
                    match_key = None
                    for p_key in list(pending_urls.keys()):
                        if safe_raw == p_key or p_key in safe_name or safe_name in p_key:
                            match_key = p_key; break
                    
                    if match_key:
                        extracted_url = pending_urls[match_key]
                        url_clean = extracted_url.replace('http://', '').replace('https://', '')
                        parts = url_clean.split(':')
                        ip = parts[0]
                        port = parts[1].split('/')[0] if len(parts) > 1 else ""
                        
                        # NEW INSTALLATION SCHEMA
                        app_config = {
                            "vmid": str(vmid),
                            "name": app.get('name', 'Unknown'),
                            "icon": app.get('icon', ''),
                            "ip": ip,
                            "port": port,
                            "url": extracted_url,
                            "category": "Dashboard",
                            "is_hidden": False
                        }
                        with open(app_json_path, 'w') as f: json.dump(app_config, f, indent=4)
                        del pending_urls[match_key]
                        config_changed = True
                    else:
                        if os.path.exists(app_json_path):
                            try:
                                with open(app_json_path, 'r') as f: app_config = json.load(f)
                            except Exception: pass
                        else:
                            # THE LOST CODE: Auto-generate the schema for any existing LXC Proxmox finds!
                            app_config = {
                                "vmid": str(vmid),
                                "name": app.get('name', 'Unknown'),
                                "icon": app.get('icon', ''),
                                "ip": "",
                                "port": "",
                                "url": f"http://{safe_raw}.local",
                                "category": "Dashboard",
                                "is_hidden": False
                            }
                            with open(app_json_path, 'w') as f: json.dump(app_config, f, indent=4)
                    
                    if "url" in app_config: app["custom_url"] = app_config["url"]
                    if "icon" in app_config: app["custom_icon"] = app_config["icon"]
                    if "is_hidden" in app_config: app["is_hidden"] = app_config["is_hidden"]
                        
                    merged_applications.append(app)
                
                if config_changed:
                    config["pending_urls"] = pending_urls
                    save_config(config)

                pulse_data["applications"] = [a for a in merged_applications if a.get("status") == "running"]
                pulse_data["stopped_apps"] = [a for a in merged_applications if a.get("status") != "running"]
                pulse_data["layout"] = {
                    "grid_order": config.get("grid_order", []),
                    "active_theme": config.get("active_theme", "odysseus"),
                    "custom_themes": config.get("custom_themes", {})
                }
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(pulse_data).encode('utf-8'))
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
                
        elif self.path == '/api/layout/load':
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(load_config()).encode('utf-8'))
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                
        elif self.path == '/api/store/catalog':
            self.handle_store_catalog()
        else:
            super().do_GET()

    def handle_store_catalog(self):
        catalog_path = 'homeos_store_catalog.json'
        if os.path.exists(catalog_path) and (time.time() - os.path.getmtime(catalog_path) < 43200):
            with open(catalog_path, 'r') as f: data = f.read()
        else:
            try:
                req = urllib.request.Request("https://api.github.com/repos/community-scripts/ProxmoxVE/contents/ct")
                req.add_header('User-Agent', 'Mozilla/5.0') 
                ctx = ssl._create_unverified_context()
                response = urllib.request.urlopen(req, context=ctx)
                gh_data = json.loads(response.read().decode('utf-8'))
                
                apps = []
                for item in gh_data:
                    if item.get('name', '').endswith('.sh') and item.get('type') == 'file':
                        app_slug = item['name'].replace('.sh', '')
                        human_name = app_slug.replace('-', ' ').title()
                        icon_url = f"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/{app_slug}.png"
                        fallback_icon = f"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/{app_slug.replace('-', '')}.png"
                        apps.append({ "id": app_slug, "name": human_name, "category": "Available Scripts", "description": f"Install {human_name} via Proxmox Helper-Scripts.", "icon": icon_url, "fallback_icon": fallback_icon, "script_url": item.get('download_url', '') })
                
                data = json.dumps({"apps": apps})
                with open(catalog_path, 'w') as f: f.write(data)
            except Exception as e:
                if os.path.exists(catalog_path):
                    with open(catalog_path, 'r') as f: data = f.read()
                else:
                    data = json.dumps({"apps": [], "warning": "Offline Mode Active"})

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(data.encode('utf-8'))

    def do_POST(self):
        if self.path == '/api/install':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            try:
                data = json.loads(post_data.decode('utf-8'))
                app_id = data.get('id')
                command = data.get('command')
                icon_url = data.get('icon_url')

                if app_id and icon_url:
                    icon_path = os.path.join(ICON_DIR, f"{app_id}.png")
                    if not os.path.exists(icon_path):
                        try:
                            req = urllib.request.Request(icon_url, headers={'User-Agent': 'HomeOS-Dashboard'})
                            ctx = ssl._create_unverified_context()
                            with urllib.request.urlopen(req, context=ctx) as response, open(icon_path, 'wb') as out_file:
                                out_file.write(response.read())
                        except Exception: pass 

                # Base64 encode to prevent command injection
                b64_command = base64.b64encode(command.encode('utf-8')).decode('utf-8')
                
                # NOTE: We REMOVED the `> /tmp/log 2>&1` pipe here. The PTY needs raw output to stream to the UI!
                safe_script = f"echo {b64_command} | base64 -d > /tmp/run_{app_id}.sh && chmod +x /tmp/run_{app_id}.sh && bash /tmp/run_{app_id}.sh"
                
                # Write the command to a secure hand-off file for terminal-engine.py
                cmd_file = f"/tmp/terminal_cmd_{app_id}.txt"
                with open(cmd_file, 'w') as f:
                    f.write(safe_script)
                
                # Instantly reply to the frontend telling it to open the WebSocket
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"success": True, "ws_port": 8081, "app_id": app_id}).encode('utf-8'))
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))
                
        elif self.path == '/api/layout/save':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            try:
                payload = json.loads(post_data.decode('utf-8'))
                config = load_config()
                if "grid_order" in payload: config["grid_order"] = payload["grid_order"]
                if "active_theme" in payload: config["active_theme"] = payload["active_theme"]
                if "custom_themes" in payload: config["custom_themes"] = payload["custom_themes"]
                save_config(config)
                    
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            except Exception as e:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))

        elif self.path == '/api/app/save':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            try:
                payload = json.loads(post_data.decode('utf-8'))
                vmid = str(payload.get('vmid'))
                if not vmid.isdigit(): raise ValueError("Invalid VMID")
                if vmid == '100': raise PermissionError("Cannot modify the master dashboard via this interface.")
                
                app_json_path = os.path.join(APP_DIR, f"{vmid}.json")
                
                pulse_data = {}
                if os.path.exists(PULSE_FILE):
                    try:
                        with open(PULSE_FILE, 'r') as f: pulse_data = json.load(f)
                    except: pass
                
                all_apps = pulse_data.get('applications', []) + pulse_data.get('stopped_apps', [])
                target_app = next((a for a in all_apps if str(a.get('id')) == vmid), {})

                # -------------------------------------------------------------
                # PHASE 3 & 4: ADVANCED PROXMOX COMMAND EXECUTION ENGINE
                # -------------------------------------------------------------
                cmd_parts = [f"pct set {vmid}"]
                if payload.get("cores"): cmd_parts.append(f"-cores {payload['cores']}")
                if payload.get("memory"): cmd_parts.append(f"-memory {payload['memory']}")
                if payload.get("swap") is not None: cmd_parts.append(f"-swap {payload['swap']}")
                if payload.get("onboot") is not None: cmd_parts.append(f"-onboot {payload['onboot']}")
                if payload.get("protection") is not None: cmd_parts.append(f"-protection {payload['protection']}")
                if "tags" in payload: cmd_parts.append(f"-tags '{payload['tags']}'")

                # THE NETWORK GUARDRAIL: Safely splice the net0 string so we don't wipe the MAC address or bridge
                if payload.get("net_mode"):
                    existing_net0 = target_app.get("config", {}).get("net0", "")
                    if existing_net0:
                        net_parts = [p for p in existing_net0.split(',') if not p.startswith('ip=') and not p.startswith('gw=')]
                        if payload["net_mode"] == "dhcp":
                            net_parts.append("ip=dhcp")
                        else:
                            if payload.get("net_ip"): net_parts.append(f"ip={payload['net_ip']}")
                            if payload.get("net_gw"): net_parts.append(f"gw={payload['net_gw']}")
                        cmd_parts.append(f"-net0 {','.join(net_parts)}")

                # Fire Core Settings to Proxmox
                if len(cmd_parts) > 1:
                    ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", f"root@{PVE_HOST}", " ".join(cmd_parts)]
                    subprocess.run(ssh_cmd, capture_output=True)

                # THE DISK GUARDRAIL: Only add space, never shrink.
                if payload.get("disk_add"):
                    try:
                        add_gb = int(payload["disk_add"])
                        if add_gb > 0:
                            disk_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", f"root@{PVE_HOST}", f"pct resize {vmid} rootfs +{add_gb}G"]
                            subprocess.run(disk_cmd, capture_output=True)
                    except: pass

                # -------------------------------------------------------------
                # LOCAL JSON DATABASE ROUTING (URL & Icon Overrides)
                # -------------------------------------------------------------
                if os.path.exists(app_json_path):
                    with open(app_json_path, 'r') as f: app_config = json.load(f)
                else:
                    app_config = {
                        "vmid": vmid,
                        "name": target_app.get('name', 'Unknown'),
                        "icon": target_app.get('icon', ''),
                        "ip": "",
                        "port": "",
                        "url": f"http://{target_app.get('raw_name', 'unknown')}.local",
                        "category": "Dashboard",
                        "is_hidden": False
                    }
                        
                if "url" in payload:
                    if payload["url"] == "": 
                        app_config["url"] = f"http://{target_app.get('raw_name', 'unknown')}.local"
                        app_config["ip"] = ""
                        app_config["port"] = ""
                    else: 
                        app_config["url"] = payload["url"]
                        url_clean = payload["url"].replace('http://', '').replace('https://', '')
                        parts = url_clean.split(':')
                        app_config["ip"] = parts[0]
                        app_config["port"] = parts[1].split('/')[0] if len(parts) > 1 else ""
                        
                if "icon" in payload:
                    if payload["icon"] == "": app_config["icon"] = target_app.get('icon', '')
                    else: app_config["icon"] = payload["icon"]
                if "is_hidden" in payload:
                    app_config["is_hidden"] = payload["is_hidden"]
                    
                with open(app_json_path, 'w') as f:
                    json.dump(app_config, f, indent=4)
                    
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            except Exception as e:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))

        elif self.path == '/api/delete_app':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            try:
                data = json.loads(post_data.decode('utf-8'))
                vmid = str(data.get('vmid'))

                if not vmid.isdigit() or vmid == '100':
                    raise PermissionError("Invalid VMID or protected dashboard instance.")

                destroy_cmd = f"pct stop {vmid}; sleep 2; pct destroy {vmid} || (qm stop {vmid}; sleep 2; qm destroy {vmid} --purge)"
                ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", f"root@{PVE_HOST}", destroy_cmd]
                
                result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=30)
                
                if result.returncode == 0:
                    app_json_path = os.path.join(APP_DIR, f"{vmid}.json")
                    if os.path.exists(app_json_path): os.remove(app_json_path)
                        
                    config = load_config()
                    if "grid_order" in config:
                        config["grid_order"] = [item for item in config["grid_order"] if item != vmid]
                        save_config(config)

                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
                else:
                    error_msg = result.stderr.strip() or result.stdout.strip() or "Unknown SSH or Proxmox Error"
                    raise Exception(f"Host Error: {error_msg}")
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))
        
        elif self.path == '/api/power':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            try:
                data = json.loads(post_data.decode('utf-8'))
                action = data.get('action')
                ctx = ssl._create_unverified_context()
                
                if action == 'host_reboot':
                    url = f"https://{PVE_HOST}:8006/api2/json/nodes/{PVE_NODE}/status"
                    payload = urllib.parse.urlencode({"command": "reboot"}).encode('utf-8')
                    req = urllib.request.Request(url, data=payload, method='POST')
                    req.add_header('Authorization', API_TOKEN)
                    response = urllib.request.urlopen(req, context=ctx)
                else:
                    vmid = data.get('vmid')
                    if not str(vmid).isdigit() or action not in ['start', 'stop', 'reboot']:
                        raise ValueError("Invalid parameters")
                    if str(vmid) == '100' and action in ['start', 'stop']:
                        raise PermissionError("Protected instance action denied")

                    url_lxc = f"https://{PVE_HOST}:8006/api2/json/nodes/{PVE_NODE}/lxc/{vmid}/status/{action}"
                    req_lxc = urllib.request.Request(url_lxc, data=b"", method='POST')
                    req_lxc.add_header('Authorization', API_TOKEN)
                    
                    try: response = urllib.request.urlopen(req_lxc, context=ctx)
                    except urllib.error.HTTPError:
                        url_qemu = f"https://{PVE_HOST}:8006/api2/json/nodes/{PVE_NODE}/qemu/{vmid}/status/{action}"
                        req_qemu = urllib.request.Request(url_qemu, data=b"", method='POST')
                        req_qemu.add_header('Authorization', API_TOKEN)
                        response = urllib.request.urlopen(req_qemu, context=ctx)
                
                if response.getcode() == 200:
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
                else:
                    raise Exception("API returned non-200 status")
            except Exception as e:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"success": False, "error": str(e)}).encode('utf-8'))
        else:
            self.send_error(404, "Not Found")

if __name__ == '__main__':
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    server = http.server.ThreadingHTTPServer(('0.0.0.0', PORT), HomeOSRequestHandler)
    server.serve_forever()