import asyncio
import websockets
import os
import pty
import fcntl
import re
import json

PVE_HOST = "__PVE_HOST__"

async def handle_terminal(websocket, path):
    app_id = path.strip('/')
    cmd_file = f"/tmp/terminal_cmd_{app_id}.txt"

    if not os.path.exists(cmd_file):
        await websocket.send(b"Error: Deployment command not found or expired.\r\n")
        return

    with open(cmd_file, 'r') as f:
        command = f.read().strip()
    os.remove(cmd_file)

    # Force SSH to allocate a PTY (-t -t)
    ssh_cmd = [
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", 
        "-t", "-t", f"root@{PVE_HOST}", command
    ]

    pid, fd = pty.fork()

    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(ssh_cmd[0], ssh_cmd)
    else:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

        loop = asyncio.get_event_loop()
        log_buffer = ""

        def pty_reader():
            nonlocal log_buffer
            try:
                data = os.read(fd, 4096)
                if data:
                    log_buffer += data.decode('utf-8', 'replace')
                    asyncio.create_task(websocket.send(data))
                else:
                    loop.remove_reader(fd)
                    asyncio.create_task(websocket.close())
            except OSError:
                loop.remove_reader(fd)
                asyncio.create_task(websocket.close())

        loop.add_reader(fd, pty_reader)

        try:
            async for message in websocket:
                if isinstance(message, str):
                    os.write(fd, message.encode('utf-8'))
                else:
                    os.write(fd, message)
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            try:
                loop.remove_reader(fd)
                os.close(fd)
                os.kill(pid, 15)
                os.waitpid(pid, 0)
            except Exception:
                pass
            
            # Auto URL Extraction (Replicating web-server.py behavior)
            urls = re.findall(r'(https?://[a-zA-Z0-9\.\-\:]+)', log_buffer)
            if urls:
                extracted_url = urls[-1]
                config_file = "/opt/dashboard/config.json"
                try:
                    with open(config_file, 'r') as f: 
                        config = json.load(f)
                    if "pending_urls" not in config: 
                        config["pending_urls"] = {}
                    config["pending_urls"][app_id.lower()] = extracted_url
                    with open(config_file, 'w') as f: 
                        json.dump(config, f, indent=4)
                except Exception:
                    pass

async def main():
    async with websockets.serve(handle_terminal, "0.0.0.0", 8081):
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())